"""Plain dataclasses for hot-path runtime state.

Distinct from ``huske.config.RuntimeConfig`` (Pydantic, frozen, validated).
These are mutable in-flight state — see ``data-model.md``.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from threading import Lock
from typing import Literal


class SessionState(StrEnum):
    STARTING = "starting"
    RECORDING = "recording"
    STOPPING = "stopping"
    STOPPED = "stopped"
    FAILED = "failed"


class ChunkState(StrEnum):
    CAPTURING = "capturing"
    FINALIZED = "finalized"
    QUEUED = "queued"
    TRANSCRIBING = "transcribing"
    TRANSCRIBED = "transcribed"
    FAILED = "failed"
    INCOMPLETE = "incomplete"


AudioSource = Literal["microphone", "system"]
TranscriptSegment = dict[str, object]


@dataclass(slots=True)
class AudioChunk:
    chunk_seq: int
    session_id: str
    start_time: datetime
    expected_duration_seconds: float
    audio_path: Path
    end_time: datetime | None = None
    actual_duration_seconds: float | None = None
    gap_seconds: float = 0.0
    transcript_path: Path | None = None
    state: ChunkState = ChunkState.CAPTURING
    failure_reason: str | None = None
    audio_sources: list[AudioSource] = field(
        default_factory=lambda: ["microphone", "system"]
    )
    # Per-source WAV paths populated by the chunker. When non-empty, this is
    # the canonical source list and the worker transcribes each file
    # independently. ``audio_path`` mirrors one of these (the first in
    # ``audio_sources``) for callers that want a single representative path.
    audio_paths: dict[AudioSource, Path] = field(default_factory=dict)

    @property
    def is_partial(self) -> bool:
        if self.actual_duration_seconds is None:
            return False
        tol = max(0.05, self.expected_duration_seconds * 0.01)
        return self.actual_duration_seconds < self.expected_duration_seconds - tol


@dataclass(slots=True)
class Transcript:
    session_id: str
    chunk_seq: int
    start_time: datetime
    end_time: datetime
    duration_seconds: int
    actual_duration_seconds: float
    gap_seconds: float
    audio_sources: list[str]
    model: str
    language: str
    incomplete: bool
    body: str
    huske_version: str
    segments: list[TranscriptSegment] | None = None

    @property
    def date(self) -> str:
        return self.start_time.date().isoformat()


@dataclass(slots=True)
class Event:
    timestamp: datetime
    severity: Literal["info", "warn", "error"]
    message: str


@dataclass
class RenderState:
    """UI-only state. Mutated from the main loop, read by the Rich render thread."""

    session_id: str = ""
    recording: bool = False
    paused: bool = False
    stopping: bool = False
    help_visible: bool = False
    current_chunk_seq: int = 0
    chunk_started_at: datetime | None = None
    next_rotation_at: datetime | None = None
    peak_levels: tuple[float, float] = (-120.0, -120.0)
    queue_depth: int = 0
    last_saved: Path | None = None
    output_root: Path | None = None
    screenshots_enabled: bool = False
    screenshots_count: int = 0
    last_screenshot_at: datetime | None = None
    events: deque[Event] = field(default_factory=lambda: deque(maxlen=5))
    warnings: dict[str, str] = field(default_factory=dict)
    _lock: Lock = field(default_factory=Lock, repr=False)

    def update(self, **fields: object) -> None:
        with self._lock:
            for k, v in fields.items():
                setattr(self, k, v)

    def push_event(self, severity: Literal["info", "warn", "error"], message: str) -> None:
        with self._lock:
            self.events.append(Event(datetime.now().astimezone(), severity, message))

    def set_warning(self, key: str, message: str) -> None:
        with self._lock:
            self.warnings[key] = message

    def clear_warning(self, key: str) -> None:
        with self._lock:
            self.warnings.pop(key, None)
