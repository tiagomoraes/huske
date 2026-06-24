"""Chunk rotator: drives WAV writers, hands off at chunk boundaries.

Each chunk has one WAV per audio source ("microphone", "system"). Writers are
opened lazily on the first ``write_block`` per source, so a chunk where only
one source produced audio yields only one WAV.

Threading model: the ``CaptureCoordinator`` mixer thread (see
``capture.coordinator``) calls ``write_block`` once per drained source per
tick. Rotation is checked on every block. The coordinator also calls
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
import numpy.typing as npt
import soundfile as sf

from huske import paths
from huske.config import RuntimeConfig
from huske.models import AudioChunk, ChunkState


class ChunkRotator:
    """Owns the current per-source WAV writers and the current chunk metadata."""

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
        self._default_audio_sources = list(default_audio_sources or ["microphone", "system"])

        self._lock = threading.Lock()
        self._writers: dict[str, sf.SoundFile] = {}
        self._chunk_paths: dict[str, Path] = {}
        self._frames_written: dict[str, int] = {}
        self._chunk_seq = 0
        self._chunk_started_at: datetime | None = None
        self._closed = False

        # Speech-gated segmentation state (see `write_block`).
        self._speech_gated = bool(cfg.speech_gated)
        self._silence_split_seconds = float(cfg.silence_split_seconds)
        self._last_speech_at: datetime | None = None

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

    def write_block(
        self,
        block: npt.NDArray[np.float32],
        source: str = "microphone",
        now: datetime | None = None,
        is_speech: bool = True,
    ) -> None:
        """Append ``block`` (mono float32) to the writer for ``source``.

        With ``speech_gated`` on, ``is_speech`` (computed once per mixer tick on
        the combined signal) drives segmentation: a chunk opens on the first
        speech block, stays open across short gaps, and closes after
        ``silence_split_seconds`` of continuous silence — so a long quiet period
        produces no file and a conversation isn't cut at a fixed clock tick.
        ``chunk_seconds`` is then only a safety cap on an unbroken monologue.

        With ``speech_gated`` off, this is the legacy behavior: open
        immediately and rotate strictly when ``chunk_seconds`` elapses
        (``is_speech`` ignored).
        """
        if self._closed:
            return
        when = now or datetime.now().astimezone()

        with self._lock:
            if self._speech_gated:
                self._write_block_gated(block, source, when, is_speech)
            else:
                self._write_block_legacy(block, source, when)

    def _write_block_legacy(
        self, block: npt.NDArray[np.float32], source: str, when: datetime
    ) -> None:
        # Rotate first if the elapsed budget is exhausted — the boundary block
        # becomes the first block of the new chunk.
        if self._chunk_started_at is not None:
            elapsed = (when - self._chunk_started_at).total_seconds()
            if elapsed >= self._cfg.chunk_seconds:
                self._close_current(when)
        if self._chunk_started_at is None:
            self._open_new_chunk(when)
        self._append(source, block)

    def _write_block_gated(
        self,
        block: npt.NDArray[np.float32],
        source: str,
        when: datetime,
        is_speech: bool,
    ) -> None:
        if self._chunk_started_at is None:
            # Idle: don't record silence. Open only when speech arrives — the
            # triggering block already contains the onset, so nothing is lost.
            if not is_speech:
                return
            self._open_new_chunk(when)  # sets _last_speech_at = when
        else:
            silence = (
                (when - self._last_speech_at).total_seconds()
                if self._last_speech_at is not None
                else 0.0
            )
            elapsed = (when - self._chunk_started_at).total_seconds()
            if silence >= self._silence_split_seconds:
                # A real pause in speech: finalize and go idle. The next speech
                # block starts a fresh chunk; the silent gap is never recorded.
                self._close_current(when)
                if not is_speech:
                    return
                self._open_new_chunk(when)
            elif elapsed >= self._cfg.chunk_seconds:
                # Safety cap on an unbroken monologue: rotate seamlessly.
                self._close_current(when)
                self._open_new_chunk(when)
            elif is_speech:
                self._last_speech_at = when

        self._append(source, block)

    def _append(self, source: str, block: npt.NDArray[np.float32]) -> None:
        writer = self._writers.get(source)
        if writer is None:
            writer = self._open_writer_for_source(source)
        writer.write(block)
        self._frames_written[source] = self._frames_written.get(source, 0) + block.shape[0]

    def finalize_current(self, now: datetime | None = None) -> None:
        """Close the current chunk (e.g., on graceful stop). Safe to call multiple times."""
        when = now or datetime.now().astimezone()
        with self._lock:
            if self._chunk_started_at is None:
                return
            self._close_current(when)
            self._closed = True

    def pause_current(self, now: datetime | None = None) -> bool:
        """Close the current chunk for a user pause, but allow later resume."""
        when = now or datetime.now().astimezone()
        with self._lock:
            if self._closed or self._chunk_started_at is None:
                return False
            self._close_current(when)
            return True

    @property
    def closed(self) -> bool:
        return self._closed

    def set_default_audio_sources(self, sources: list[str]) -> None:
        """Update the default audio_sources tag for newly-opened chunks."""
        with self._lock:
            self._default_audio_sources = list(sources)

    # ------------------------------------------------------------------ inner

    def _open_new_chunk(self, when: datetime) -> None:
        self._chunk_seq += 1
        self._chunk_started_at = when
        # Reset the silence timer so a just-opened chunk never immediately
        # splits (matters for the max-cap seamless-rotation path).
        self._last_speech_at = when
        self._writers = {}
        self._chunk_paths = {}
        self._frames_written = {}

    def _open_writer_for_source(self, source: str) -> sf.SoundFile:
        assert self._chunk_started_at is not None
        path = paths.audio_chunk_path(
            self._cfg,
            self._session_id,
            self._chunk_seq,
            self._chunk_started_at,
            source=source,
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        writer = sf.SoundFile(
            str(path),
            mode="w",
            samplerate=self._cfg.sample_rate,
            channels=1,
            subtype="PCM_16",
        )
        self._writers[source] = writer
        self._chunk_paths[source] = path
        self._frames_written.setdefault(source, 0)
        return writer

    def _close_current(self, when: datetime) -> None:
        assert self._chunk_started_at is not None

        for writer in self._writers.values():
            writer.close()

        # Sources that actually received frames, ordered by `default_audio_sources`
        # (anything unexpected appended at the end).
        sources_used: list[str] = []
        for s in self._default_audio_sources:
            if s in self._chunk_paths:
                sources_used.append(s)
        for s in self._chunk_paths:
            if s not in sources_used:
                sources_used.append(s)

        max_frames = max(self._frames_written.values()) if self._frames_written else 0
        actual = max_frames / float(self._cfg.sample_rate)

        primary_path = (
            self._chunk_paths[sources_used[0]]
            if sources_used
            else Path()
        )

        # In speech-gated mode a chunk closes on a real pause (or the cap), so
        # its natural length IS its full length — it is not a truncated
        # ("partial"/incomplete) chunk the way a short legacy fixed-interval
        # chunk would be. Setting expected == actual makes ``is_partial`` False
        # and reports the recorded length as ``duration_seconds``. Recovery
        # still marks its chunks incomplete explicitly.
        expected = actual if self._speech_gated else self._cfg.chunk_seconds

        chunk = AudioChunk(
            chunk_seq=self._chunk_seq,
            session_id=self._session_id,
            start_time=self._chunk_started_at,
            expected_duration_seconds=expected,
            audio_path=primary_path,
            audio_paths=dict(self._chunk_paths),  # type: ignore[arg-type]
            audio_sources=list(sources_used),  # type: ignore[arg-type]
            end_time=when,
            actual_duration_seconds=actual,
            state=ChunkState.FINALIZED,
        )

        self._writers = {}
        self._chunk_paths = {}
        self._frames_written = {}
        self._chunk_started_at = None

        names = ", ".join(p.name for p in chunk.audio_paths.values())
        self._on_event(
            "info",
            f"chunk {chunk.chunk_seq} finalized ({actual:.1f}s) → {names or chunk.audio_path.name}",
        )
        self._on_finalized(chunk)
