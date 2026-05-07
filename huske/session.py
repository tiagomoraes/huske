"""RecordingSession orchestrator: lifecycle, lock files, state machine."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from huske import paths
from huske.config import RuntimeConfig
from huske.models import AudioChunk, SessionState


@dataclass
class RecordingSession:
    config: RuntimeConfig
    session_id: str = field(default_factory=paths.generate_session_id)
    started_at: datetime = field(default_factory=lambda: datetime.now().astimezone())
    ended_at: datetime | None = None
    chunks: list[AudioChunk] = field(default_factory=list)
    state: SessionState = SessionState.STARTING

    @property
    def audio_root(self) -> Path:
        return paths.audio_root(self.config, self.session_id)

    @property
    def lock_path(self) -> Path:
        return paths.lock_path(self.audio_root)

    @property
    def output_root(self) -> Path:
        return self.config.output_root

    def ensure_dirs(self) -> None:
        paths.ensure_dirs(self.config, self.session_id)

    def acquire_lock(self) -> None:
        self.ensure_dirs()
        self.lock_path.write_text(str(os.getpid()), encoding="utf-8")

    def release_lock(self) -> None:
        try:
            self.lock_path.unlink(missing_ok=True)
        except OSError:
            pass


def is_lock_alive(lock_file: Path) -> bool:
    """True if the lock file references a currently-running process."""
    try:
        pid = int(lock_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False
    return True
