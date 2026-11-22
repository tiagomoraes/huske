"""A session lock left by a crash, whose PID now belongs to someone else.

``audio_root/<session>/.lock`` holds the PID of the ``huske run`` that wrote
it. A crashed session leaves it behind; when that PID is later given to an
unrelated process, a bare "is the PID running" check calls the dead session
alive: every ``huske inbox process`` defers to it and crash recovery skips its
chunks until something else takes the inbox. The lock's modification time
says when the session took it, and a session cannot be older than its lock.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from collections.abc import Iterator
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from huske import session as session_mod
from huske.config import RuntimeConfig
from huske.inbox.processor import live_session_running
from huske.recovery.scanner import scan_orphans
from huske.session import RecordingSession, is_lock_alive, process_start_time


@pytest.fixture
def cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        inbox_root=tmp_path / "inbox",
        sample_rate=8000,
        channels=1,
    )


@pytest.fixture
def bystander() -> Iterator[subprocess.Popen[bytes]]:
    """An unrelated process that is running right now (it got "the" PID)."""
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        yield proc
    finally:
        proc.kill()
        proc.wait(timeout=10)


def _lock_written_long_ago(directory: Path, pid: int, *, age_seconds: float = 3600.0) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    lock = directory / ".lock"
    lock.write_text(str(pid), encoding="utf-8")
    then = time.time() - age_seconds
    os.utime(lock, (then, then))
    return lock


def test_the_start_time_of_a_running_process_is_known(bystander: subprocess.Popen[bytes]) -> None:
    started = process_start_time(bystander.pid)
    assert started is not None
    assert abs(started - time.time()) < 30.0
    own = process_start_time(os.getpid())
    assert own is not None and own <= started + 1.0


def test_no_start_time_for_a_process_that_is_gone() -> None:
    assert process_start_time(99_999_999) is None


def test_a_lock_a_running_session_just_wrote_is_alive(cfg: RuntimeConfig) -> None:
    session = RecordingSession(cfg)
    session.acquire_lock()
    assert is_lock_alive(session.lock_path)
    assert live_session_running(cfg)


def test_a_lock_naming_a_dead_pid_is_stale(tmp_path: Path) -> None:
    lock = tmp_path / ".lock"
    lock.write_text("99999999", encoding="utf-8")
    assert not is_lock_alive(lock)


@pytest.mark.parametrize("content", ["0", "-1", "", "not a pid"])
def test_a_lock_that_names_no_process_is_stale(tmp_path: Path, content: str) -> None:
    lock = tmp_path / ".lock"
    lock.write_text(content, encoding="utf-8")
    assert not is_lock_alive(lock)


def test_a_lock_whose_pid_was_reused_is_stale(
    tmp_path: Path, bystander: subprocess.Popen[bytes]
) -> None:
    # Written an hour ago by a session that crashed; its PID is now the
    # bystander's, which started a moment ago.
    lock = _lock_written_long_ago(tmp_path / "20261119T150000_dead", bystander.pid)
    assert not is_lock_alive(lock)


def test_a_long_running_session_keeps_its_old_lock(tmp_path: Path) -> None:
    # This process is older than a lock it wrote just now, and stays older
    # however long the session runs: the lock's time never moves.
    lock = tmp_path / ".lock"
    lock.write_text(str(os.getpid()), encoding="utf-8")
    assert is_lock_alive(lock)


def test_a_small_clock_difference_is_not_a_reused_pid(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = tmp_path / ".lock"
    lock.write_text(str(os.getpid()), encoding="utf-8")
    written = lock.stat().st_mtime
    # The process start reads a little after the lock (clock stepped back
    # while the engine was starting): still the same session.
    monkeypatch.setattr(session_mod, "process_start_time", lambda pid: written + 2.0)
    assert is_lock_alive(lock)
    monkeypatch.setattr(session_mod, "process_start_time", lambda pid: written + 60.0)
    assert not is_lock_alive(lock)


def test_an_unknown_start_time_leaves_the_lock_alive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lock = tmp_path / ".lock"
    lock.write_text(str(os.getpid()), encoding="utf-8")
    monkeypatch.setattr(session_mod, "process_start_time", lambda pid: None)
    assert is_lock_alive(lock)


def test_a_reused_pid_does_not_make_a_one_shot_pass_defer(
    cfg: RuntimeConfig, bystander: subprocess.Popen[bytes]
) -> None:
    _lock_written_long_ago(cfg.audio_root / "20261119T150000_dead", bystander.pid)
    assert not live_session_running(cfg)


def test_a_reused_pid_does_not_hide_a_crashed_session_from_recovery(
    cfg: RuntimeConfig, bystander: subprocess.Popen[bytes]
) -> None:
    session_dir = cfg.audio_root / "20260507T091500_aaaa1111"
    _lock_written_long_ago(session_dir, bystander.pid)
    sf.write(
        str(session_dir / "0001_091500.wav"),
        np.zeros((16_000, 1), dtype=np.float32),
        8000,
        subtype="PCM_16",
    )

    orphans = scan_orphans(cfg)

    assert [o.session_id for o in orphans] == ["20260507T091500_aaaa1111"]
    assert orphans[0].chunks and orphans[0].chunks[0].valid
