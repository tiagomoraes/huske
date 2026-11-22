"""Legacy mlx-whisper transcription engine.

Kept selectable (``asr_engine = "whisper"``) for parity and fallback. Whisper
is autoregressive and hallucinates short repeated phrases on quiet
non-speech, so this engine pairs the model with an energy gate that drops any
segment whose audio window sits near the source's noise floor. (Parakeet does
not need this — it emits nothing on silence — which is why it is the default.)

Audio is loaded as a 16 kHz mono float32 array and handed to
``mlx_whisper.transcribe`` directly, so this path needs no ffmpeg either.

**Language** is pinned through Whisper's language token (``language="pt"``):
every window decodes as that language. **The custom dictionary** reaches the
model as ``initial_prompt`` — Whisper imitates the spellings it has just
"seen". Two details make that work in practice:

* mlx-whisper keeps only the *last* 223 prompt tokens, so the prompt is built
  to fit (``Vocabulary.whisper_prompt``, measured with Whisper's tokenizer);
* with ``condition_on_previous_text=False`` (which we need: it stops
  hallucination loops) mlx-whisper applies ``initial_prompt`` to the first
  30-s window only. :func:`_carry_prompt` re-attaches it to every window —
  the behaviour openai-whisper calls ``carry_initial_prompt``, which
  mlx-whisper lacks.

A prompted model can echo its prompt over silence; :func:`looks_like_prompt`
drops a segment that is just the dictionary read back.
"""

from __future__ import annotations

import dataclasses
import re
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from functools import lru_cache
from typing import TYPE_CHECKING, Any

from huske.transcribe.engines.base import (
    TARGET_SAMPLE_RATE,
    Segment,
    TranscriptionEngine,
)

if TYPE_CHECKING:
    import numpy as np
    import numpy.typing as npt

    from huske.transcribe.vocabulary import Vocabulary

# Energy-gate thresholds (carried over from the previous worker). A segment is
# kept only if its audio window's RMS or peak clears an adaptive floor derived
# from the quietest fifth of the file — conservative, and fails open on error.
_ENERGY_BLOCK_SECONDS = 0.10
_SEGMENT_CONTEXT_SECONDS = 0.20
_MIN_ENERGY_WINDOW_SECONDS = 0.35
_ABSOLUTE_RMS_FLOOR = 10 ** (-55.0 / 20.0)
_ABSOLUTE_PEAK_FLOOR = 10 ** (-42.0 / 20.0)
_MAX_RMS_FLOOR = 10 ** (-42.0 / 20.0)
_MAX_PEAK_FLOOR = 10 ** (-30.0 / 20.0)
_NOISE_RMS_PERCENTILE = 20.0
_RMS_NOISE_MULTIPLIER = 3.0
_PEAK_NOISE_MULTIPLIER = 8.0


class _EnergyGate:
    """Decide whether a transcribed window carries real signal, from the array."""

    def __init__(self, audio: npt.NDArray[np.float32], sample_rate: int) -> None:
        import numpy as np

        self._audio = audio
        self._sr = sample_rate
        block = max(1, round(sample_rate * _ENERGY_BLOCK_SECONDS))
        if audio.size:
            n_blocks = audio.size // block
            trimmed = audio[: n_blocks * block] if n_blocks else audio
            if n_blocks:
                rms = np.sqrt(np.mean(np.square(trimmed.reshape(n_blocks, block), dtype=np.float64), axis=1))
            else:
                rms = np.array([_rms(audio)])
            noise = float(np.percentile(rms, _NOISE_RMS_PERCENTILE)) if rms.size else 0.0
        else:
            noise = 0.0
        self.rms_floor = max(_ABSOLUTE_RMS_FLOOR, min(_MAX_RMS_FLOOR, noise * _RMS_NOISE_MULTIPLIER))
        self.peak_floor = max(_ABSOLUTE_PEAK_FLOOR, min(_MAX_PEAK_FLOOR, noise * _PEAK_NOISE_MULTIPLIER))

    def has_signal(self, start_s: float, end_s: float) -> bool:
        import numpy as np

        if self._audio.size == 0:
            return False
        start = max(0.0, start_s - _SEGMENT_CONTEXT_SECONDS)
        end = max(end_s + _SEGMENT_CONTEXT_SECONDS, start + _MIN_ENERGY_WINDOW_SECONDS)
        a = min(self._audio.size, max(0, int(start * self._sr)))
        b = min(self._audio.size, max(a + 1, int(end * self._sr)))
        window = self._audio[a:b]
        if window.size == 0:
            return False
        return _rms(window) >= self.rms_floor or float(np.abs(window).max()) >= self.peak_floor


@contextmanager
def _nullcontext() -> Iterator[None]:
    yield


def _rms(data: Any) -> float:
    import numpy as np

    if data.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(data, dtype=np.float64))))


_WORD_RE = re.compile(r"\w+", re.UNICODE)


def _words(text: str) -> list[str]:
    return [w.casefold() for w in _WORD_RE.findall(text)]


def looks_like_prompt(text: str, prompt: str | None, spellings: list[str]) -> bool:
    """True when ``text`` is the dictionary prompt read back, not speech.

    Either the segment is a piece of the prompt itself (two words or more), or
    it is three or more words that are almost all dictionary terms.
    """
    if not prompt:
        return False
    words = _words(text)
    if not words:
        return False
    prompt_words = _words(prompt)
    joined, haystack = " ".join(words), " ".join(prompt_words)
    if len(words) >= 2 and f" {joined} " in f" {haystack} ":
        return True
    vocab_words = {w for term in spellings for w in _words(term)}
    if len(words) >= 3 and vocab_words:
        hits = sum(1 for w in words if w in vocab_words)
        return hits / len(words) >= 0.75
    return False


@lru_cache(maxsize=4)
def _token_counter(language: str | None) -> Callable[[str], int] | None:
    """Count tokens with Whisper's own tokenizer (no model weights needed)."""
    try:
        from mlx_whisper.tokenizer import get_tokenizer

        tokenizer = get_tokenizer(
            True, num_languages=100, language=language or "en", task="transcribe"
        )
    except Exception:
        return None
    return lambda text: len(tokenizer.encode(" " + text.strip()))


@contextmanager
def _carry_prompt(tokens: list[int]) -> Iterator[None]:
    """Give every 30-s window the dictionary prompt, not just the first.

    mlx-whisper rebuilds ``DecodingOptions(prompt=…)`` per window and, with
    ``condition_on_previous_text=False``, leaves it empty after window one.
    We wrap ``Whisper.decode`` for the duration of one ``transcribe`` call
    (the worker subprocess runs one job at a time) and fill an empty prompt
    with the initial-prompt tokens. A window that already has a prompt is
    left alone.
    """
    try:
        from mlx_whisper import whisper as whisper_module
    except Exception:
        yield
        return
    original = whisper_module.Whisper.decode

    def decode(model: Any, mel: Any, options: Any = None, **kwargs: Any) -> Any:
        if options is not None and not options.prompt:
            options = dataclasses.replace(options, prompt=list(tokens))
        if options is None:
            return original(model, mel, **kwargs)
        return original(model, mel, options, **kwargs)

    whisper_module.Whisper.decode = decode
    try:
        yield
    finally:
        whisper_module.Whisper.decode = original


class WhisperEngine(TranscriptionEngine):
    def __init__(
        self,
        model_size: str | None = None,
        *,
        repo: str | None = None,
        label: str | None = None,
        fp16: bool = True,
        language: str | None = None,
    ) -> None:
        """Load ``repo`` (any mlx-whisper model: HF repo or local folder), or a
        legacy ``model_size`` ("base", "large-v3-turbo", …)."""
        if repo is None:
            from huske.config import mlx_whisper_repo

            repo = mlx_whisper_repo(model_size or "base")
        self._model_size = model_size
        self._repo = repo
        self._fp16 = fp16
        self._language = language
        self._vocabulary: Vocabulary | None = None
        self.model_label = label or f"mlx-whisper:{model_size or repo.rsplit('/', 1)[-1]}"

    def initial_prompt(self) -> str | None:
        """The dictionary as an ``initial_prompt`` that fits Whisper's budget."""
        if self._vocabulary is None or self._vocabulary.is_empty:
            return None
        return self._vocabulary.whisper_prompt(
            self._language, count_tokens=_token_counter(self._language)
        )

    def transcribe(self, audio: npt.NDArray[np.float32]) -> list[Segment]:
        import mlx_whisper

        if audio.size == 0:
            return []
        gate = _EnergyGate(audio, TARGET_SAMPLE_RATE)

        kwargs: dict[str, Any] = {
            "path_or_hf_repo": self._repo,
            "fp16": self._fp16,
            "verbose": None,
            "condition_on_previous_text": False,
        }
        if self._language:
            kwargs["language"] = self._language

        prompt = self.initial_prompt()
        if prompt:
            kwargs["initial_prompt"] = prompt
            tokens = self._prompt_tokens(prompt)
            with _carry_prompt(tokens) if tokens else _nullcontext():
                result = mlx_whisper.transcribe(audio, **kwargs)
        else:
            result = mlx_whisper.transcribe(audio, **kwargs)
        spellings = self._vocabulary.spellings() if self._vocabulary else []
        segments: list[Segment] = []
        for seg in result.get("segments") or []:
            text = (seg.get("text") or "").strip()
            if not text:
                continue
            if looks_like_prompt(text, prompt, spellings):
                continue
            start = float(seg.get("start", 0.0))
            end = float(seg.get("end", start))
            if not gate.has_signal(start, end):
                continue
            segments.append(Segment(start=start, end=max(end, start), text=text))
        segments.sort(key=lambda s: s.start)
        return segments

    def _prompt_tokens(self, prompt: str) -> list[int]:
        try:
            from mlx_whisper.tokenizer import get_tokenizer

            tokenizer = get_tokenizer(
                True, num_languages=100, language=self._language or "en", task="transcribe"
            )
            return list(tokenizer.encode(" " + prompt.strip()))
        except Exception:
            return []

    def unload(self) -> None:
        try:
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.model = None
            ModelHolder.model_path = None
        except Exception:
            pass
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:
            pass
