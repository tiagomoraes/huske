"""Legacy mlx-whisper transcription engine.

Kept selectable (``asr_engine = "whisper"``) for parity and fallback. Whisper
is autoregressive and hallucinates short repeated phrases on quiet
non-speech, so this engine pairs the model with an energy gate that drops any
segment whose audio window sits near the source's noise floor. (Parakeet does
not need this — it emits nothing on silence — which is why it is the default.)

Audio is loaded as a 16 kHz mono float32 array and handed to
``mlx_whisper.transcribe`` directly, so this path needs no ffmpeg either.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from huske.transcribe.engines.base import (
    TARGET_SAMPLE_RATE,
    Segment,
    TranscriptionEngine,
    load_mono_16k,
)

if TYPE_CHECKING:
    import numpy as np
    import numpy.typing as npt

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


def _rms(data: Any) -> float:
    import numpy as np

    if data.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(data, dtype=np.float64))))


class WhisperEngine(TranscriptionEngine):
    def __init__(
        self,
        model_size: str = "base",
        *,
        fp16: bool = True,
        language: str | None = None,
    ) -> None:
        from huske.config import mlx_whisper_repo

        self._model_size = model_size
        self._repo = mlx_whisper_repo(model_size)
        self._fp16 = fp16
        self._language = language
        self.model_label = f"mlx-whisper:{model_size}"

    def transcribe(self, wav_path: str) -> list[Segment]:
        import mlx_whisper

        audio = load_mono_16k(wav_path)
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

        result = mlx_whisper.transcribe(audio, **kwargs)
        segments: list[Segment] = []
        for seg in result.get("segments") or []:
            text = (seg.get("text") or "").strip()
            if not text:
                continue
            start = float(seg.get("start", 0.0))
            end = float(seg.get("end", start))
            if not gate.has_signal(start, end):
                continue
            segments.append(Segment(start=start, end=max(end, start), text=text))
        segments.sort(key=lambda s: s.start)
        return segments

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
