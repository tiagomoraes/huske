"""LLM post-processing of one transcript: raw snapshot → corrected → marked.

``distill_transcript`` is the one shared code path for the live worker, the
``huske distill`` backfill and one-shot inbox processing:

1. The raw transcript is already on disk — the ASR worker wrote it first.
   Snapshot it to ``<name>.asr.txt`` (once; later passes reuse the snapshot,
   so the raw text is always recoverable and a re-run never drifts).
2. Correct the snapshot's ``[HH:MM:SS · source]`` runs through
   :mod:`huske.distill.correction` (batching, prompts, per-line validation).
3. Atomically rewrite the canonical ``.md``: same frontmatter plus
   ``postprocessed_by`` / ``postprocessed_at`` / ``raw_transcript``, same
   heading, corrected runs.

A failure before step 3 leaves the raw ``.md`` exactly as the ASR wrote it.

The backend is anything with ``complete(instructions, prompt, max_tokens)``:
the built-in MLX child, Ollama, Apple Intelligence (``huske-apple-llm``), an
OpenAI-compatible server, OpenAI, Anthropic or OpenRouter — see
:func:`build_distiller` and ``huske/distill/providers.py``.
"""

from __future__ import annotations

import hashlib
import os
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import yaml

from huske.distill.client import DistillError
from huske.distill.correction import (
    CompletionBackend,
    CorrectionResult,
    build_instructions,
    correct_texts,
    input_budget,
    parse_reply,
)
from huske.distill.models import Statement, StatementSidecar
from huske.distill.providers import Target, consent_granted, resolve_target
from huske.paths import asr_raw_path
from huske.search.models import Run
from huske.search.parser import ParseError, parse_transcript
from huske.transcribe.vocabulary import Vocabulary

_FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?(.*)\Z", re.DOTALL)
_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

#: Frontmatter keys a post-processing pass owns (transcript-format contract).
POSTPROCESS_KEYS = ("postprocessed_by", "postprocessed_at", "raw_transcript")

#: Transcript tokens per request, by provider. Small models clean short
#: excerpts and pass long ones through nearly untouched, so this is a quality
#: budget; :func:`input_budget` clamps it further to the context window.
QUALITY_TOKENS: dict[str, int] = {
    "mlx": 250,
    "apple": 300,
    "ollama": 350,
    "openai_compatible": 400,
    "openai": 1500,
    "anthropic": 1500,
    "openrouter": 1500,
    "fake": 1500,
}


class HeuristicDistiller:
    """Deterministic identity backend for tests and ``distill_model = "heuristic"``.

    Echoes every numbered line unchanged — no model, no network — so the full
    snapshot → batch → parse → rewrite path runs in tests.
    """

    provider = "fake"
    backend = "fake"
    model_id = "heuristic"

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        del instructions, max_tokens
        body = prompt.replace("<transcript>", "").replace("</transcript>", "")
        lines = parse_reply(body, 100_000)
        return "\n".join(f"[{i}] {text}" for i, text in sorted(lines.items()))


@dataclass
class TranscriptCorrector:
    """A backend plus everything a pass needs besides the transcript itself."""

    backend: CompletionBackend
    vocabulary: Vocabulary
    instructions: str = ""
    fallback_language: str | None = None
    context_tokens: int = 4096
    max_output_tokens: int = 1800
    quality_tokens: int = 300

    @property
    def provider(self) -> str:
        return str(getattr(self.backend, "provider", "fake"))

    @property
    def model_id(self) -> str:
        return str(getattr(self.backend, "model_id", ""))

    @property
    def label(self) -> str:
        """``<provider>:<model>``, recorded as ``postprocessed_by``."""
        return f"{self.provider}:{self.model_id or 'default'}"

    @property
    def pid(self) -> int | None:
        pid = getattr(self.backend, "pid", None)
        return int(pid) if isinstance(pid, int) and pid > 0 else None

    def close(self) -> None:
        closer = getattr(self.backend, "close", None)
        if callable(closer):
            closer()

    def _context(self) -> int:
        # Apple reports its real window (8,192 on macOS 27 / M3+, 4,096 on
        # older Macs); never assume more than the model has.
        reported = getattr(self.backend, "context_tokens", None)
        if isinstance(reported, int) and reported > 0:
            return min(self.context_tokens, reported)
        return self.context_tokens

    def correct_runs(self, texts: list[str], *, language: str | None) -> CorrectionResult:
        lang = language or self.fallback_language
        status = getattr(self.backend, "status", None)
        if callable(status) and getattr(self.backend, "context_tokens", 0) is None:
            status()  # learn Apple's real context window before sizing batches
        system = build_instructions(language=lang, vocabulary=self.vocabulary, extra=self.instructions)
        budget = input_budget(
            quality_tokens=self.quality_tokens,
            context_tokens=self._context(),
            instructions=system,
            max_output_tokens=self.max_output_tokens,
        )
        return correct_texts(
            self.backend,
            texts,
            language=lang,
            vocabulary=self.vocabulary,
            instructions=self.instructions,
            max_input_tokens=budget,
            max_output_tokens=self.max_output_tokens,
        )


def build_backend(cfg: Any, target: Target | None = None) -> CompletionBackend:
    """The completion backend for ``cfg.distill_backend``."""
    model = getattr(cfg, "distill_model", None)
    if model in ("heuristic", "fake"):
        return HeuristicDistiller()
    target = target or resolve_target(cfg)
    timeout = float(getattr(cfg, "distill_timeout_seconds", 120.0))
    name = target.name
    if name == "mlx":
        from huske.distill.mlx_backend import MLXDistiller

        return MLXDistiller(target.model or "", timeout=timeout)
    if name == "ollama":
        from huske.distill.client import OllamaClient
        from huske.distill.ollama_backend import OllamaBackend

        client = OllamaClient(target.endpoint or "", timeout=timeout)
        return OllamaBackend(client, target.model or "", think=bool(cfg.distill_think))
    if name == "apple":
        from huske.distill.apple import AppleBackend

        return AppleBackend(timeout=timeout)
    from huske.distill import keychain
    from huske.distill.http_llm import AnthropicBackend, OpenAICompatibleBackend

    key = keychain.get_key(name) if target.provider.accepts_key else None
    if target.provider.needs_key and not key:
        raise DistillError(
            f"no {target.provider.label} API key in the Keychain; add one in Huske.app or "
            f"with `huske llm key set {name}`",
            kind="auth",
        )
    consented = consent_granted(target, cfg)
    if name == "anthropic":
        return AnthropicBackend(target, consented=consented, api_key=key, timeout=timeout)
    return OpenAICompatibleBackend(target, consented=consented, api_key=key, timeout=timeout)


def build_distiller(cfg: Any, *, backend: CompletionBackend | None = None) -> TranscriptCorrector:
    """A :class:`TranscriptCorrector` for ``cfg`` (the configured backend unless given)."""
    target = resolve_target(cfg)
    chosen = backend or build_backend(cfg, target)
    provider = str(getattr(chosen, "provider", target.name))
    return TranscriptCorrector(
        backend=chosen,
        vocabulary=Vocabulary.from_runtime_config(cfg),
        instructions=str(getattr(cfg, "distill_instructions", "") or ""),
        fallback_language=getattr(cfg, "language", None),
        context_tokens=target.context_tokens,
        max_output_tokens=target.provider.max_output_tokens,
        quality_tokens=QUALITY_TOKENS.get(provider, 300),
    )


def ensure_asr_raw(transcript_path: Path) -> Path:
    """Copy the first-seen ``.md`` to ``.asr.txt``; later calls reuse that snapshot."""
    raw = asr_raw_path(transcript_path)
    if not raw.exists():
        tmp = raw.with_name(raw.name + ".tmp")
        tmp.write_bytes(transcript_path.read_bytes())
        os.replace(tmp, raw)
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


def _update_front(front: str, updates: dict[str, str] | None) -> str:
    """Replace the post-processing keys in raw frontmatter text, leave the rest."""
    if updates is None:
        return front
    kept = [
        line
        for line in front.split("\n")
        if not any(line.startswith(f"{key}:") for key in POSTPROCESS_KEYS)
    ]
    for key, value in updates.items():
        dumped = yaml.safe_dump({key: value}, allow_unicode=True, width=10_000).rstrip("\n")
        kept.append(dumped)
    return "\n".join(kept)


def rewrite_transcript_body(
    path: Path, body: str, *, front_updates: dict[str, str] | None = None
) -> None:
    """Atomically replace the body of an existing transcript; keep frontmatter."""
    raw = path.read_text(encoding="utf-8")
    match = _FRONTMATTER_RE.match(raw)
    if not match:
        raise ParseError(f"{path}: missing YAML frontmatter")
    front = _update_front(match.group(1), front_updates)
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


def distill_transcript(
    path: Path,
    corrector: TranscriptCorrector | CompletionBackend,
    *,
    now: datetime | None = None,
    **_legacy: Any,
) -> StatementSidecar:
    """Snapshot raw ASR, correct each run, rewrite ``.md``, assemble the sidecar.

    Raises :class:`DistillError` (transport, timeout, auth, consent…) before
    touching the ``.md``, which then stays exactly as the ASR wrote it.
    """
    if not isinstance(corrector, TranscriptCorrector):
        corrector = TranscriptCorrector(backend=corrector, vocabulary=Vocabulary())
    path = path.resolve()
    raw_path = ensure_asr_raw(path)
    source_sha = hashlib.sha256(raw_path.read_bytes()).hexdigest()
    # Always correct from the raw snapshot so a re-run cannot drift the polish.
    doc = parse_transcript(raw_path)
    language = None if doc.language in ("", "auto") else doc.language

    result = corrector.correct_runs([run.text or "" for run in doc.runs], language=language)

    corrected_runs: list[Run] = []
    statements: list[Statement] = []
    for run, text in zip(doc.runs, result.texts, strict=True):
        end = run.end or doc.end_time
        sources = [run.source] if run.source else []
        corrected_runs.append(Run(start=run.start, source=run.source, text=text, end=end))
        if text:
            statements.append(Statement(text=text, start=run.start, end=end, sources=sources))

    stamp = (now or datetime.now().astimezone()).isoformat(timespec="seconds")
    rewrite_transcript_body(
        path,
        body_from_runs(corrected_runs),
        front_updates={
            "postprocessed_by": corrector.label,
            "postprocessed_at": stamp,
            "raw_transcript": raw_path.name,
        },
    )
    return StatementSidecar(
        transcript_path=str(path),
        session_id=doc.session_id,
        source_sha256=source_sha,
        model=corrector.model_id,
        backend=corrector.provider,
        distilled_at=stamp,
        statements=statements,
    )
