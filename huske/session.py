"""RecordingSession orchestrator: lifecycle, lock files, state machine."""

from __future__ import annotations

import ctypes
import os
import sys
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


# A session takes its lock a moment after its process starts, so a process
# that started later than the lock was written is not that session: the PID
# was handed to someone else after a crash. The margin absorbs coarse process
# start times and a clock that stepped back while the engine was starting; a
# PID cannot come round again within it.
LOCK_START_SLACK_SECONDS = 10.0

_PROC_PIDTBSDINFO = 3
_MAXCOMLEN = 16


class _ProcBSDInfo(ctypes.Structure):
    """``struct proc_bsdinfo`` (<sys/proc_info.h>), for ``proc_pidinfo``."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * _MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * _MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def process_start_time(pid: int) -> float | None:
    """When process ``pid`` started (Unix seconds), or None if it cannot be told.

    macOS: ``proc_pidinfo`` (no subprocess; this runs about once a second
    during a one-shot inbox pass). Elsewhere: the age of ``/proc/<pid>``.
    """
    if pid <= 0:
        return None
    if sys.platform == "darwin":
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            info = _ProcBSDInfo()
            size = ctypes.sizeof(info)
            got = libc.proc_pidinfo(
                ctypes.c_int(pid),
                ctypes.c_int(_PROC_PIDTBSDINFO),
                ctypes.c_uint64(0),
                ctypes.byref(info),
                ctypes.c_int(size),
            )
        except (OSError, AttributeError, ValueError):
            return None
        if got != size or info.pbi_pid != pid or info.pbi_start_tvsec == 0:
            return None
        return float(info.pbi_start_tvsec) + float(info.pbi_start_tvusec) / 1e6
    try:
        return os.stat(f"/proc/{pid}").st_mtime
    except OSError:
        return None


def is_lock_alive(lock_file: Path) -> bool:
    """True if the lock file belongs to a session that is still running.

    The process it names must be running *and* be at least as old as the lock:
    after a crash the PID can be given to an unrelated process, which would
    otherwise keep a dead session "alive" for as long as it runs (one-shot
    inbox passes defer to it, crash recovery skips its chunks). The lock's
    modification time is when the session took it, so no format change is
    needed and locks written by older engines are checked the same way. When
    the start time cannot be read, the PID check alone decides, as before.
    """
    try:
        pid = int(lock_file.read_text(encoding="utf-8").strip())
        written_at = lock_file.stat().st_mtime
    except (OSError, ValueError):
        return False
    if pid <= 0:
        return False  # never a session; `kill(0, 0)` would answer for our own group
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False
    started_at = process_start_time(pid)
    if started_at is None:
        return True
    return started_at <= written_at + LOCK_START_SLACK_SECONDS
