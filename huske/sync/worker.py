"""Coalescing background Git sync for the recording process.

The hot path only enqueues a notification. One lightweight daemon thread owns
the managed checkout and collapses bursts of finalized transcripts into a
single pull/commit/push cycle. Git commits are the durable retry queue, so an
offline Mac catches up at the next session without another database.
"""

from __future__ import annotations

import queue
import threading
from typing import Any

from huske.sync.client import SyncError, TranscriptPublisher

_SYNC = "sync"
_STOP = "stop"


class SyncWorker:
    def __init__(
        self,
        publisher: TranscriptPublisher,
        *,
        max_attempts: int = 6,
        reconcile_on_start: bool = True,
    ) -> None:
        self._publisher = publisher
        self._max_attempts = max_attempts
        self._reconcile_on_start = reconcile_on_start
        self._queue: queue.Queue[str] = queue.Queue()
        self._events: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self.alive:
            return
        self._thread = threading.Thread(target=self._loop, name="huske-sync", daemon=True)
        self._thread.start()

    def submit(self, transcript_path: str = "") -> None:
        """Request reconciliation; ``transcript_path`` is an observability hint."""
        self._queue.put(transcript_path or _SYNC)

    def poll_event(self, timeout: float = 0.0) -> dict[str, Any] | None:
        try:
            return self._events.get(timeout=timeout)
        except queue.Empty:
            return None

    def stop(self, drain_timeout: float = 10.0) -> None:
        if self._thread is None:
            return
        self._stop.set()
        self._queue.put(_STOP)
        self._thread.join(timeout=drain_timeout)
        self._thread = None

    @property
    def alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def _loop(self) -> None:
        if self._reconcile_on_start:
            self._queue.put(_SYNC)
        attempts = 0
        while True:
            if self._stop.is_set() and self._queue.empty():
                return
            try:
                item = self._queue.get(timeout=0.25)
            except queue.Empty:
                continue
            if item == _STOP:
                continue

            # The publisher scans the full immutable tree, so one run covers
            # every transcript notification already queued.
            while True:
                try:
                    queued = self._queue.get_nowait()
                    if queued == _STOP:
                        self._stop.set()
                except queue.Empty:
                    break

            try:
                result = self._publisher.sync()
            except SyncError as exc:
                attempts += 1
                self._events.put(
                    {
                        "ok": False,
                        "error": str(exc),
                        "attempts": attempts,
                        "retryable": exc.retryable,
                    }
                )
                if (
                    not self._stop.is_set()
                    and exc.retryable
                    and attempts < self._max_attempts
                ):
                    delay = min(30.0, 2.0 ** min(attempts, 5))
                    if not self._stop.wait(delay):
                        self._queue.put(_SYNC)
                continue
            except Exception as exc:
                attempts += 1
                self._events.put(
                    {"ok": False, "error": f"sync failed: {exc}", "attempts": attempts}
                )
                continue

            attempts = 0
            self._events.put(
                {
                    "ok": True,
                    "changed": result.changed,
                    "commit": result.commit,
                    "pushed": result.pushed,
                }
            )
