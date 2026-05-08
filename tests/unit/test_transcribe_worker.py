"""Tests for the transcription worker process wrapper."""

from __future__ import annotations

import os
import signal
import time
from typing import Any

from huske.transcribe import worker


def _sigint_ignoring_child(ready_q: Any) -> None:
    worker._configure_worker_signal_handlers()
    ready_q.put(os.getpid())
    time.sleep(5.0)


def test_worker_child_ignores_sigint_until_parent_stops_it() -> None:
    ready_q: Any = worker._ctx.Queue()
    proc: Any = worker._ctx.Process(target=_sigint_ignoring_child, args=(ready_q,))
    proc.start()
    try:
        pid = ready_q.get(timeout=5.0)
        os.kill(pid, signal.SIGINT)

        proc.join(timeout=0.75)

        assert proc.is_alive()
    finally:
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=2.0)
        if proc.is_alive():
            proc.kill()
            proc.join(timeout=2.0)
        try:
            ready_q.cancel_join_thread()
        except (OSError, ValueError):
            pass
        try:
            ready_q.close()
        except (OSError, ValueError):
            pass
