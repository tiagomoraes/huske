"""Per-run ASR correction, behind a small protocol.

A tiny local model (default Qwen3.5 0.8B) fixes typos and obvious ASR
mishears in one transcript run. It must not summarise, translate, or invent.
``HeuristicDistiller`` is a deterministic identity stand-in used by the test
suite and by ``--model heuristic``.

``distill_transcript`` is the one shared code path: snapshot the raw Markdown
to ``.asr.txt``, correct each ``[HH:MM:SS · source]`` run, rewrite the
canonical ``.md`` body, and assemble the skip-hash sidecar. Both the live
worker and the ``huske distill`` backfill call it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from huske.distill.models import Statement, StatementSidecar
from huske.paths import asr_raw_path
from huske.search.models import Run
from huske.search.parser import ParseError, parse_transcript

_FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?(.*)\Z", re.DOTALL)
_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


@runtime_checkable
class Distiller(Protocol):
    """Turns one run's ASR text into a one-item list ``[corrected]``."""

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


def build_prompt(text: str, *, sources: list[str], language: str, max_statements: int = 1) -> str:
    """Conservative correction instruction for one transcript run. JSON-out."""
    del max_statements  # kept so older callers/tests keep working
    lang_hint = (
        "Keep the same language as the excerpt."
        if not language or language == "auto"
        else f"Keep the excerpt in {language}. Do not translate."
    )
    return (
        "You correct automatic speech-recognition errors in one transcript excerpt. "
        "Rules:\n"
        "- Fix typos, missing punctuation, obvious mishears, and broken casing.\n"
        "- Do NOT add, remove, summarise, or paraphrase facts. Do NOT invent names "
        "or numbers that are not clearly implied by the excerpt.\n"
        "- If the excerpt is already fine, return it unchanged.\n"
        f"- {lang_hint}\n"
        f"- {_source_legend(sources)}\n"
        'Respond ONLY with JSON of the form {"text": "..."}.\n\n'
        "Excerpt:\n"
        f"{text}"
    )


def _extract_corrected_text(data: Any) -> str | None:
    if isinstance(data, str):
        text = data.strip()
        return text or None
    if isinstance(data, dict):
        for key in ("text", "corrected", "correction"):
            value = data.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        if len(data) == 1:
            value = next(iter(data.values()))
            if isinstance(value, str) and value.strip():
                return value.strip()
    return None


def acceptable_correction(original: str, candidate: str) -> bool:
    """Reject empty replies and wild length swings from a tiny model."""
    orig = original.strip()
    cand = candidate.strip()
    if not cand:
        return False
    if not orig:
        return True
    o_len, c_len = len(orig), len(cand)
    if o_len >= 16 and c_len < int(o_len * 0.5):
        return False
    if c_len > max(int(o_len * 2.5), o_len + 80):
        return False
    return True


def parse_correction(raw: str, original: str) -> str:
    """Parse ``{"text": "..."}`` (and a few small-model shapes) or keep ``original``."""
    try:
        data: Any = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return original
    candidate = _extract_corrected_text(data)
    if candidate is None or not acceptable_correction(original, candidate):
        return original
    return candidate


def parse_statements(raw: str, max_statements: int = 1) -> list[str]:
    """Compatibility wrapper: a one-item ``[corrected]`` list (or empty)."""
    del max_statements
    # Empty / unusable JSON must not look like a successful identity correction.
    try:
        data: Any = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return []
    candidate = _extract_corrected_text(data)
    if candidate is None:
        return []
    return [candidate]


def apply_correction(original: str, raw_reply: str) -> str:
    """Return a conservative correction, or ``original`` when the reply is unusable."""
    return parse_correction(raw_reply, original)


class OllamaDistiller:
    """Corrects via a local Ollama model. See :class:`huske.distill.client.OllamaClient`."""

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
        # think=False by default — correction needs no reasoning pass (see config).
        raw = self._client.chat(
            self.model_id,
            prompt,
            json_format=True,
            think=self._think,
            options={"temperature": 0.0, "num_predict": 512},
        )
        return [apply_correction(text, raw)]


class HeuristicDistiller:
    """Deterministic identity distiller for tests and ``--model heuristic``.

    Returns the run unchanged. Not a real model — it never reaches a network —
    but it exercises snapshot → per-run correct → rewrite → sidecar without a
    daemon.
    """

    model_id = "heuristic"
    backend = "fake"

    def __init__(self, *, max_statements: int = 8) -> None:
        self._max = max_statements

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]:
        del sources, language
        stripped = text.strip()
        return [stripped] if stripped else []


def build_distiller(
    model: str,
    *,
    backend: str = "mlx",
    endpoint: str = "http://127.0.0.1:11434",
    timeout: float = 120.0,
    max_statements: int = 8,
    think: bool = False,
) -> Distiller:
    """Construct the distiller for ``model``.

    ``heuristic`` / ``fake`` → the dependency-free identity distiller. Backend
    ``ollama`` → a daemon-backed distiller pointed at ``endpoint`` (``think``
    enables its reasoning pass; correction does not need it). Anything else →
    the built-in MLX backend, which runs the model itself in an isolated
    subprocess (no daemon; downloads from Hugging Face on first use).
    """
    if model in ("heuristic", "fake"):
        return HeuristicDistiller(max_statements=max_statements)
    if backend == "ollama":
        from huske.distill.client import OllamaClient

        client = OllamaClient(endpoint, timeout=timeout)
        return OllamaDistiller(client, model, max_statements=max_statements, think=think)
    from huske.distill.mlx_backend import MLXDistiller

    return MLXDistiller(model, max_statements=max_statements, timeout=timeout)


def ensure_asr_raw(transcript_path: Path) -> Path:
    """Copy the first-seen ``.md`` to ``.asr.txt``; later calls reuse that snapshot."""
    raw = asr_raw_path(transcript_path)
    if not raw.exists():
        raw.write_bytes(transcript_path.read_bytes())
    return raw


def source_sha256_for(transcript_path: Path) -> str:
    """Hash the raw ASR snapshot when present, otherwise the live ``.md``."""
    raw = asr_raw_path(transcript_path)
    target = raw if raw.exists() else transcript_path
    return hashlib.sha256(target.read_bytes()).hexdigest()


def body_from_runs(runs: list[Run]) -> str:
    """Rebuild the ``[HH:MM:SS · source] text`` body from corrected runs."""
    blocks: list[str] = []
    for run in runs:
        text = (run.text or "").strip()
        if not text:
            continue
        ts = run.start.strftime("%H:%M:%S")
        source = run.source or "mic"
        blocks.append(f"[{ts} · {source}] {text}")
    return "\n\n".join(blocks)


def _heading(start: datetime, end: datetime) -> str:
    day = _DAYS[start.weekday()]
    return (
        f"# {start.strftime('%H:%M')} – {end.strftime('%H:%M')} "  # noqa: RUF001
        f"({day} {start.date().isoformat()})"
    )


def rewrite_transcript_body(path: Path, body: str) -> None:
    """Atomically replace the body of an existing transcript; keep frontmatter."""
    raw = path.read_text(encoding="utf-8")
    match = _FRONTMATTER_RE.match(raw)
    if not match:
        raise ParseError(f"{path}: missing YAML frontmatter")
    front = match.group(1)
    rest = match.group(2).lstrip("\n")
    heading = ""
    if rest.startswith("#"):
        heading, _, _tail = rest.partition("\n")
        heading = heading.strip()
    if not heading:
        # Fall back to a heading derived from frontmatter times if the file
        # has no H1 (legacy / hand-edited). parse_transcript already validated.
        doc = parse_transcript(path)
        heading = _heading(doc.start_time, doc.end_time)
    cleaned = body.strip() if body and body.strip() else "_(no speech detected)_"
    rendered = f"---\n{front}\n---\n\n{heading}\n\n{cleaned}\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(rendered, encoding="utf-8")
    os.replace(tmp, path)


def _correct_run(distiller: Distiller, run: Run, *, language: str) -> str:
    original = (run.text or "").strip()
    if not original:
        return original
    sources = [run.source] if run.source else []
    claims = distiller.distill_passage(original, sources=sources, language=language)
    candidate = claims[0].strip() if claims else original
    if not acceptable_correction(original, candidate):
        return original
    return candidate


def distill_transcript(
    path: Path,
    distiller: Distiller,
    *,
    max_statements_per_passage: int = 8,
    now: datetime | None = None,
) -> StatementSidecar:
    """Snapshot raw ASR, correct each run, rewrite ``.md``, assemble the sidecar."""
    del max_statements_per_passage
    path = path.resolve()
    raw_path = ensure_asr_raw(path)
    source_sha = hashlib.sha256(raw_path.read_bytes()).hexdigest()
    # Always correct from the raw snapshot so a re-run cannot drift the polish.
    doc = parse_transcript(raw_path)
    key = str(path)

    corrected_runs: list[Run] = []
    statements: list[Statement] = []
    for run in doc.runs:
        text = _correct_run(distiller, run, language=doc.language)
        end = run.end or doc.end_time
        sources = [run.source] if run.source else []
        corrected_runs.append(
            Run(start=run.start, source=run.source, text=text, end=end)
        )
        if text:
            statements.append(
                Statement(text=text, start=run.start, end=end, sources=sources)
            )

    rewrite_transcript_body(path, body_from_runs(corrected_runs))

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
