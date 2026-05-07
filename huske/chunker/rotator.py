"""Chunk rotator: drives WAV writers, hands off at chunk boundaries.

Threading model: the ``CaptureCoordinator`` mixer thread (see
``capture.coordinator``) calls ``write_block`` with mixed mono frames.
Rotation is checked on every block. The coordinator also calls
``finalize_current`` on graceful stop.

Callbacks (``on_finalized``, ``on_event``) are invoked from the mixer
thread — implementations must be thread-safe.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import soundfile as sf

from huske import paths
from huske.config import RuntimeConfig
from huske.models import AudioChunk, ChunkState


class ChunkRotator:
    """Owns the current SoundFile writer and the current AudioChunk metadata."""

    def __init__(
        self,
        cfg: RuntimeConfig,
        session_id: str,
        on_finalized: Callable[[AudioChunk], None],
        on_event: Callable[[str, str], None] | None = None,
        default_audio_sources: list[str] | None = None,
    ) -> None:
        self._cfg = cfg
        self._session_id = session_id
        self._on_finalized = on_finalized
        self._on_event = on_event or (lambda _sev, _msg: None)
        self._default_audio_sources = default_audio_sources or ["microphone", "system"]

        self._lock = threading.Lock()
        self._writer: sf.SoundFile | None = None
        self._chunk: AudioChunk | None = None
        self._chunk_seq = 0
        self._chunk_started_at: datetime | None = None
        self._frames_written = 0
        self._closed = False

    @property
    def current_chunk(self) -> AudioChunk | None:
        return self._chunk

    @property
    def current_chunk_seq(self) -> int:
        return self._chunk_seq

    @property
    def chunk_started_at(self) -> datetime | None:
        return self._chunk_started_at

    @property
    def next_rotation_at(self) -> datetime | None:
        if self._chunk_started_at is None:
            return None
        return self._chunk_started_at + timedelta(seconds=self._cfg.chunk_seconds)

    def _open_new_chunk(self, when: datetime) -> None:
        self._chunk_seq += 1
        audio_path = paths.audio_chunk_path(
            self._cfg, self._session_id, self._chunk_seq, when
        )
        audio_path.parent.mkdir(parents=True, exist_ok=True)
        self._writer = sf.SoundFile(
            str(audio_path),
            mode="w",
            samplerate=self._cfg.sample_rate,
            channels=self._cfg.channels,
            subtype="PCM_16",
        )
        self._chunk = AudioChunk(
            chunk_seq=self._chunk_seq,
            session_id=self._session_id,
            start_time=when,
            expected_duration_seconds=self._cfg.chunk_seconds,
            audio_path=audio_path,
            audio_sources=list(self._default_audio_sources),  # type: ignore[arg-type]
        )
        self._chunk_started_at = when
        self._frames_written = 0

    def write_block(self, block: np.ndarray, now: datetime | None = None) -> None:
        """Append ``block`` (frames × channels) to the current chunk.

        Rotates BEFORE writing if the configured chunk duration has elapsed —
        the boundary block becomes the first block of the new chunk so the
        finalized chunk's audio length is at most ``chunk_seconds``.
        """
        if self._closed:
            return
        when = now or datetime.now().astimezone()

        with self._lock:
            # Rotate first if the elapsed budget is exhausted.
            if self._chunk is not None and self._writer is not None:
                elapsed = (when - self._chunk.start_time).total_seconds()
                if elapsed >= self._cfg.chunk_seconds:
                    self._close_current(when)

            if self._writer is None or self._chunk is None:
                self._open_new_chunk(when)

            assert self._writer is not None and self._chunk is not None
            self._writer.write(block)
            self._frames_written += block.shape[0]

    def finalize_current(self, now: datetime | None = None) -> None:
        """Close the current chunk (e.g., on graceful stop). Safe to call multiple times."""
        when = now or datetime.now().astimezone()
        with self._lock:
            if self._writer is None or self._chunk is None:
                return
            self._close_current(when)
            self._closed = True

    def _close_current(self, when: datetime) -> None:
        assert self._writer is not None and self._chunk is not None
        self._writer.close()
        self._writer = None

        actual = self._frames_written / float(self._cfg.sample_rate)
        self._chunk.end_time = when
        self._chunk.actual_duration_seconds = actual
        self._chunk.state = ChunkState.FINALIZED

        finalized = self._chunk
        self._chunk = None
        self._on_event(
            "info",
            f"chunk {finalized.chunk_seq} finalized ({actual:.1f}s) → {finalized.audio_path.name}",
        )
        self._on_finalized(finalized)

    @property
    def closed(self) -> bool:
        return self._closed

    def set_default_audio_sources(self, sources: list[str]) -> None:
        """Update the default audio_sources tag for newly-opened chunks."""
        with self._lock:
            self._default_audio_sources = list(sources)
