"""Pluggable transcription engines, organised as *families*.

A **family** is one runtime and one way of decoding — Parakeet (``parakeet-mlx``)
or Whisper (``mlx-whisper``) today. A **model** is a set of weights a family can
load (``mlx-community/parakeet-tdt-0.6b-v3``, ``…/whisper-large-v3-turbo``).
Models are data: they live in ``huske/transcribe/models.toml``, and any
compatible Hugging Face repo or local folder works too (``huske models use``).

Adding a model of an existing family = one catalog entry (or nothing: point
``asr_model`` at the repo). Adding a **new family** (another runtime) = one
module with a :class:`TranscriptionEngine` subclass plus one
:func:`register_family` call below — the worker, the config, the CLI and the
app all go through this registry, so nothing else changes. See
``docs/transcription-models.md``.

Families declare what they can do, so every surface states it honestly:

* ``pins_language`` — the model takes the spoken language as an input
  (Whisper's language token). Parakeet infers it per window and cannot be told.
* ``dictionary`` — how the custom dictionary biases decoding: ``"prompt"``
  (Whisper's ``initial_prompt``), ``"boost"`` (Parakeet word boosting, opt-in)
  or ``"none"``. The deterministic corrections and LLM cleanup work for all.

Both shipped families load 16 kHz mono audio with ``soundfile`` + ``soxr`` (no
ffmpeg) and run on MLX/Metal — Apple Silicon only. Heavy imports happen inside
the builders, so importing this module stays cheap.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from importlib.util import find_spec
from typing import Literal

from huske.transcribe.engines.base import Segment, TranscriptionEngine

__all__ = [
    "FAMILIES",
    "EngineFamily",
    "Segment",
    "TranscriptionEngine",
    "build_engine",
    "register_family",
]

DictionarySupport = Literal["prompt", "boost", "none"]


@dataclass(frozen=True)
class EngineFamily:
    """One transcription runtime and what it can do."""

    name: str
    label: str
    #: Prefix of the ``model:`` frontmatter value, e.g. ``mlx-whisper``.
    label_prefix: str
    pins_language: bool
    dictionary: DictionarySupport
    #: Importable module the family needs; checked before a model is offered.
    runtime: str
    #: ``(repo, label, language, compute_type) -> engine``; imports lazily.
    builder: Callable[[str, str, str | None, str], TranscriptionEngine]
    #: Prefix stripped from a repo name to make the short label.
    repo_prefix: str = ""

    def available(self) -> bool:
        try:
            return find_spec(self.runtime) is not None
        except (ImportError, ValueError):
            return False


FAMILIES: dict[str, EngineFamily] = {}


def register_family(family: EngineFamily) -> None:
    """Make ``family`` available to the config, the worker, the CLI and the app."""
    FAMILIES[family.name] = family


def _build_parakeet(repo: str, label: str, language: str | None, _ct: str) -> TranscriptionEngine:
    from huske.transcribe.engines.parakeet import ParakeetEngine

    engine = ParakeetEngine(model_id=repo, language=language)
    engine.model_label = label
    return engine


def _build_whisper(repo: str, label: str, language: str | None, ct: str) -> TranscriptionEngine:
    from huske.transcribe.engines.whisper import WhisperEngine

    return WhisperEngine(repo=repo, label=label, fp16=ct != "float32", language=language)


register_family(
    EngineFamily(
        name="parakeet",
        label="Parakeet",
        label_prefix="parakeet",
        pins_language=False,
        dictionary="boost",
        runtime="parakeet_mlx",
        builder=_build_parakeet,
        repo_prefix="parakeet-",
    )
)
register_family(
    EngineFamily(
        name="whisper",
        label="Whisper",
        label_prefix="mlx-whisper",
        pins_language=True,
        dictionary="prompt",
        runtime="mlx_whisper",
        builder=_build_whisper,
        repo_prefix="whisper-",
    )
)


def build_engine(
    family: str,
    *,
    repo: str,
    label: str,
    language: str | None = None,
    compute_type: str = "int8",
) -> TranscriptionEngine:
    """Construct the engine for ``repo`` with the family's builder."""
    try:
        fam = FAMILIES[family]
    except KeyError as exc:
        raise ValueError(f"unknown transcription engine family: {family!r}") from exc
    return fam.builder(repo, label, language, compute_type)
