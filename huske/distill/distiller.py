"""Passage → Statements, behind a small protocol.

``OllamaDistiller`` is the production path: it prompts a local model for atomic,
faithful claims and parses the JSON back. ``HeuristicDistiller`` is a
deterministic, dependency-free stand-in (splits on sentences) used by the test
suite and by ``--model heuristic`` — the same "test the pipeline without the
heavy backend" trick ``HashingEmbedder`` plays for embeddings.

``distill_transcript`` is the one shared code path: parse the ``.md`` → window
into Passages (reusing ``huske.search``) → distill each Passage → assemble the
sidecar. Both the live worker and the ``huske distill`` backfill call it.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from huske.distill.models import Statement, StatementSidecar
from huske.search.parser import parse_transcript
from huske.search.windowing import window

_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?…])\s+")


@runtime_checkable
class Distiller(Protocol):
    """Turns one Passage's text into a list of self-contained claim strings."""

    model_id: str
    backend: str

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]: ...


def _source_legend(sources: list[str]) -> str:
    have = set(sources)
    if have == {"mic"}:
        return "The speaker is the user."
    if have == {"system"}:
        return "The speaker is the other party (system audio)."
    return "Speakers: mic = the user, system = the other party."


def build_prompt(text: str, *, sources: list[str], language: str, max_statements: int) -> str:
    """The distillation instruction for one Passage. Faithful, atomic, JSON-out."""
    lang_hint = (
        "Write each statement in the same language as the excerpt."
        if not language or language == "auto"
        else f"Write each statement in {language}."
    )
    return (
        "You extract atomic, self-contained factual statements from an excerpt of "
        "a transcribed conversation. Rules:\n"
        "- Each statement is ONE sentence, understandable on its own (resolve "
        "pronouns and references using the excerpt).\n"
        "- Be faithful: state only what the excerpt supports. Do NOT invent, infer, "
        "or speculate beyond the text.\n"
        "- Capture decisions, facts, requests, questions, and commitments; skip "
        "greetings, filler, and backchannel.\n"
        f"- Return at most {max_statements} statements. If the excerpt has no "
        "substantive content, return an empty list.\n"
        f"- {lang_hint}\n"
        f"- {_source_legend(sources)}\n"
        'Respond ONLY with JSON of the form {"statements": ["...", "..."]}.\n\n'
        "Excerpt:\n"
        f"{text}"
    )


def parse_statements(raw: str, max_statements: int) -> list[str]:
    """Parse the model's JSON reply into a clean, de-duplicated claim list.

    Tolerant of the common shapes a small model emits: ``{"statements": [...]}``,
    a bare list, or a dict whose only value is the list.
    """
    try:
        data: Any = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return []

    items: Any
    if isinstance(data, dict):
        items = data.get("statements")
        if items is None and len(data) == 1:
            items = next(iter(data.values()))
    elif isinstance(data, list):
        items = data
    else:
        items = None
    if not isinstance(items, list):
        return []

    out: list[str] = []
    seen: set[str] = set()
    for item in items:
        text = item.strip() if isinstance(item, str) else str(item).strip()
        if not text or text.lower() in seen:
            continue
        seen.add(text.lower())
        out.append(text)
        if len(out) >= max_statements:
            break
    return out


class OllamaDistiller:
    """Distills via a local Ollama model. See :class:`huske.distill.client.OllamaClient`."""

    def __init__(
        self, client: Any, model: str, *, max_statements: int = 8, think: bool = False
    ) -> None:
        self.model_id = model
        self.backend = "ollama"
        self._client = client
        self._max = max_statements
        self._think = think

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]:
        prompt = build_prompt(text, sources=sources, language=language, max_statements=self._max)
        # temperature 0 for faithfulness; num_predict caps a runaway generation.
        # think=False by default — extraction needs no reasoning pass (see config).
        raw = self._client.chat(
            self.model_id,
            prompt,
            json_format=True,
            think=self._think,
            options={"temperature": 0.0, "num_predict": 512},
        )
        return parse_statements(raw, self._max)


class HeuristicDistiller:
    """Deterministic, dependency-free distiller for tests and ``--model heuristic``.

    Splits a Passage into sentences and returns the first ``max_statements``.
    Not a real model — it never reaches a network — but it exercises the full
    parse → window → sidecar → embed → search pipeline without a daemon.
    """

    model_id = "heuristic"
    backend = "fake"

    def __init__(self, *, max_statements: int = 8) -> None:
        self._max = max_statements

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]:
        parts = [p.strip() for p in _SENTENCE_SPLIT_RE.split(text.strip()) if p.strip()]
        return parts[: self._max]


def build_distiller(
    model: str,
    *,
    endpoint: str = "http://127.0.0.1:11434",
    timeout: float = 120.0,
    max_statements: int = 8,
    think: bool = False,
) -> Distiller:
    """Construct the distiller for ``model``.

    ``heuristic`` / ``fake`` → the dependency-free test distiller; anything else
    → an Ollama-backed distiller pointed at ``endpoint``. ``think`` enables the
    model's reasoning pass (off by default; extraction does not need it).
    """
    if model in ("heuristic", "fake"):
        return HeuristicDistiller(max_statements=max_statements)
    from huske.distill.client import OllamaClient

    client = OllamaClient(endpoint, timeout=timeout)
    return OllamaDistiller(client, model, max_statements=max_statements, think=think)


def distill_transcript(
    path: Path,
    distiller: Distiller,
    *,
    max_statements_per_passage: int = 8,
    now: datetime | None = None,
) -> StatementSidecar:
    """Parse → window → distill each Passage → assemble the sidecar for ``path``."""
    path = path.resolve()
    source_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    doc = parse_transcript(path)
    key = str(path)
    passages = window(doc, doc_key=key)

    statements: list[Statement] = []
    for p in passages:
        claims = distiller.distill_passage(p.text, sources=list(p.sources), language=doc.language)
        for claim in claims[:max_statements_per_passage]:
            claim = claim.strip()
            if claim:
                statements.append(
                    Statement(text=claim, start=p.start, end=p.end, sources=list(p.sources))
                )

    stamp = (now or datetime.now().astimezone()).isoformat(timespec="seconds")
    return StatementSidecar(
        transcript_path=key,
        session_id=doc.session_id,
        source_sha256=source_sha,
        model=getattr(distiller, "model_id", ""),
        backend=getattr(distiller, "backend", ""),
        distilled_at=stamp,
        statements=statements,
    )
