"""Engine interface + shared, ffmpeg-free audio loading.

The transcript pipeline only ever needs 16 kHz mono float32 — that is what
both Whisper and Parakeet consume. huske captures at 48 kHz, so each engine
resamples once on load. We do it here with ``soundfile`` (already a base
dependency) + ``soxr`` (a small, high-quality resampler that ships with
``parakeet-mlx``), deliberately avoiding the ``ffmpeg`` subprocess that both
``mlx_whisper.load_audio`` and ``parakeet_mlx``'s own loader shell out to — so
transcription has no hidden CLI dependency.
"""

from __future__ import annotations

import abc
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np
    import numpy.typing as npt

# Both engines run on 16 kHz mono.
TARGET_SAMPLE_RATE = 16000


@dataclass(slots=True)
class Segment:
    """One transcribed span within a single source's WAV.

    ``start`` / ``end`` are seconds offset from the start of the WAV file (which
    the worker maps to wall-clock via ``chunk_start + start``). ``source`` is
    filled in by the worker after the engine returns (the engine transcribes one
    source at a time and does not know which). ``confidence`` is in [0, 1] when
    the engine reports it (Parakeet does; Whisper leaves it ``None``).
    """

    start: float
    end: float
    text: str
    source: str = ""
    confidence: float | None = None
    #: Set by cross-channel echo de-duplication when this (mic) segment is an
    #: acoustic echo of a system segment. The worker drops or annotates it.
    echo: bool = False


def load_mono_16k(path: str) -> npt.NDArray[np.float32]:
    """Load ``path`` as a 16 kHz mono float32 numpy array (no ffmpeg).

    Reads with ``soundfile``, downmixes to mono, and resamples to 16 kHz with
    ``soxr`` when needed. Raises if the file can't be read — the worker treats
    that as a per-chunk failure.
    """
    import numpy as np
    import soundfile as sf

    data, sr = sf.read(path, dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != TARGET_SAMPLE_RATE:
        import soxr

        data = soxr.resample(data, sr, TARGET_SAMPLE_RATE)
    out: npt.NDArray[np.float32] = np.ascontiguousarray(data, dtype=np.float32)
    return out


class TranscriptionEngine(abc.ABC):
    """Turns a per-source WAV into ``Segment``s.

    One instance is built per session and reused across chunks; the heavy model
    is loaded lazily on first ``transcribe`` and may be dropped by ``unload``
    during idle gaps (the next call reloads it). Implementations run inside the
    spawned worker subprocess, never in the main process.
    """

    #: ``<engine>:<short-model>`` recorded in transcript frontmatter, e.g.
    #: ``parakeet:tdt-0.6b-v3`` or ``mlx-whisper:medium``.
    model_label: str = "unknown"

    @abc.abstractmethod
    def transcribe(self, wav_path: str) -> list[Segment]:
        """Transcribe one source's WAV into time-ordered, non-empty segments."""

    def unload(self) -> None:
        """Drop the resident model so the OS can reclaim it during idle gaps.

        Best-effort and idempotent; the next ``transcribe`` reloads. Default is
        a no-op for engines that hold no reclaimable state.
        """
        return None
