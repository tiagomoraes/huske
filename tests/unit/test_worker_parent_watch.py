"""The ASR worker exits when the process that started it dies.

Killing ``huske inbox process`` (Huske.app's watchdog sends SIGTERM; a crash
or ``kill -9`` gives it no chance to clean up) used to leave the spawned
``huske-asr`` worker re-parented to launchd: it kept transcribing for nobody
at full CPU and held the dead parent's stdout/stderr pipes open, which kept
whoever was reading them waiting for an EOF that never came.

Kept free of heavy imports at module level: the last test spawns real
processes, and each one imports this module.
"""

from __future__ import annotations

import os
import queue
import signal
import time
from pathlib import Path
from typing import Any

import pytest

from huske.transcribe import worker


def test_the_watch_exits_the_worker_once_its_parent_is_gone() -> None:
    answers = iter([False, False, False, True])
    asked: list[int] = []
    slept: list[float] = []
    orphaned: list[str] = []

    def is_gone(pid: int) -> bool:
        asked.append(pid)
        return next(answers)

    thread = worker._watch_parent(
        4242,
        interval=0.25,
        is_gone=is_gone,
        on_orphaned=lambda: orphaned.append("exit"),
        sleep=slept.append,
    )
    thread.join(timeout=5.0)

    assert not thread.is_alive()
    assert thread.daemon, "the watch must never keep a finished worker alive"
    assert asked == [4242, 4242, 4242, 4242]
    assert slept == [0.25, 0.25, 0.25], "one sleep per check while the parent lives"
    assert orphaned == ["exit"], "exits once, and only after the parent is gone"


def test_parent_is_gone_compares_with_the_pid_captured_at_start() -> None:
    assert worker._parent_is_gone(os.getppid()) is False
    # Re-parented (to launchd, pid 1): the parent pid is no longer the one
    # the worker was started with.
    assert worker._parent_is_gone(os.getppid() + 1) is True


class _RecordingProcess:
    def __init__(self, *, target: Any, args: tuple[Any, ...], name: str) -> None:
        self.target = target
        self.args = args
        self.name = name
        self.started = False

    def start(self) -> None:
        self.started = True

    def is_alive(self) -> bool:
        return self.started


class _RecordingContext:
    Queue = queue.Queue
    Process = _RecordingProcess


def test_the_worker_is_started_with_its_parents_pid(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(worker, "_ctx", _RecordingContext())
    transcriber = worker.TranscriptionWorker()

    transcriber.start()

    proc = transcriber._proc
    assert proc.target is worker._worker_main
    # Taken in the parent, not `getppid()` in the child: a parent that dies
    # while the child is still starting up is noticed too.
    assert proc.args[3] == os.getpid()


def test_worker_main_watches_only_a_parent_it_was_given(monkeypatch: pytest.MonkeyPatch) -> None:
    from ._inbox_fakes import FakeEngine, install_fake_asr

    install_fake_asr(monkeypatch, FakeEngine())
    watched: list[int] = []
    monkeypatch.setattr(worker, "_watch_parent", lambda pid, **_: watched.append(pid))

    in_q: queue.Queue[Any] = queue.Queue()
    out_q: queue.Queue[Any] = queue.Queue()
    in_q.put(worker._SENTINEL)
    worker._worker_main(in_q, out_q, {"recycle_idle_process": False}, 4242)
    assert watched == [4242]

    # Run on a thread (as the inbox tests do) there is no parent to outlive,
    # and exiting the process would take the caller down with it.
    in_q.put(worker._SENTINEL)
    worker._worker_main(in_q, out_q, {"recycle_idle_process": False})
    assert watched == [4242]


# --- a real orphan -----------------------------------------------------------


def _orphan_child(pid_file: str, parent_pid: int) -> None:
    """Stands in for the worker: starts the watch, then is busy for a minute."""
    worker._watch_parent(parent_pid, interval=0.05)
    tmp = f"{pid_file}.tmp"
    Path(tmp).write_text(str(os.getpid()), encoding="utf-8")
    os.replace(tmp, pid_file)
    time.sleep(60.0)


def _orphan_parent(pid_file: str) -> None:
    """Stands in for `huske inbox process`: starts a worker, then is killed."""
    child = worker._ctx.Process(target=_orphan_child, args=(pid_file, os.getpid()))
    child.start()
    time.sleep(60.0)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _wait_until(condition: Any, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return bool(condition())


def test_a_worker_whose_parent_is_killed_exits(tmp_path: Path) -> None:
    pid_file = tmp_path / "child.pid"
    parent: Any = worker._ctx.Process(target=_orphan_parent, args=(str(pid_file),))
    parent.start()
    child_pid: int | None = None
    try:
        assert _wait_until(pid_file.exists, 30.0), "the child never started"
        child_pid = int(pid_file.read_text(encoding="utf-8"))
        # While its parent lives the watch leaves it alone (many poll intervals).
        time.sleep(0.5)
        assert _alive(child_pid)

        os.kill(parent.pid, signal.SIGKILL)  # no cleanup, no goodbye
        parent.join(timeout=5.0)

        gone = _wait_until(lambda: not _alive(child_pid or 0), 10.0)
        assert gone, "the orphaned worker kept running after its parent died"
    finally:
        if parent.is_alive():
            parent.kill()
            parent.join(timeout=2.0)
        if child_pid is not None and _alive(child_pid):
            os.kill(child_pid, signal.SIGKILL)
