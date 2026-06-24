"""Pluggable transcription engines.

A transcription engine turns a finalized per-source WAV into a list of
``Segment``s (start/end offsets in seconds within the WAV, plus text and an
optional confidence). The worker subprocess (``huske.transcribe.worker``)
builds one engine per session, transcribes each source's WAV, tags the
segments with their source, de-duplicates cross-channel echo, and renders the
Markdown transcript.

Two engines ship today:

* ``parakeet`` — NVIDIA Parakeet (TDT) via the MLX port ``parakeet-mlx``. The
  default. Non-autoregressive, so it emits nothing on silence/noise instead of
  hallucinating repeated tokens the way Whisper does, and it auto-detects the
  language (multilingual on ``parakeet-tdt-0.6b-v3``). See ``parakeet.py``.
* ``whisper`` — the legacy mlx-whisper path, kept selectable. Pairs with an
  energy gate to suppress its silence hallucinations. See ``whisper.py``.

Both load 16 kHz mono audio with ``soundfile`` + ``soxr`` (no ffmpeg
dependency) and run on the same MLX/Metal stack — Apple Silicon only.
"""

from __future__ import annotations

from huske.transcribe.engines.base import Segment, TranscriptionEngine

__all__ = ["Segment", "TranscriptionEngine", "build_engine"]


def build_engine(
    engine: str,
    *,
    model: str,
    parakeet_model: str,
    language: str | None = None,
    compute_type: str = "int8",
) -> TranscriptionEngine:
    """Construct the configured transcription engine.

    ``engine`` is ``"parakeet"`` or ``"whisper"``. Heavy backend imports happen
    inside each engine's constructor so importing this module stays cheap and
    the base recording pipeline never pulls MLX in eagerly.
    """
    if engine == "parakeet":
        from huske.transcribe.engines.parakeet import ParakeetEngine

        return ParakeetEngine(model_id=parakeet_model)
    if engine == "whisper":
        from huske.transcribe.engines.whisper import WhisperEngine

        fp16 = compute_type != "float32"
        return WhisperEngine(model_size=model, fp16=fp16, language=language)
    raise ValueError(f"unknown transcription engine: {engine!r}")
