"""Coalescing background Git sync for the recording process.

The hot path only enqueues a notification. One lightweight daemon thread owns
the managed checkout and collapses bursts of finalized transcripts into a
single pull/commit/push cycle. The transcript tree is the durable outbox, so an
offline Mac catches up as soon as the network is back: retryable failures are
retried on a capped backoff for as long as the session runs, and every new
transcript triggers an immediate attempt.
"""

from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass
from typing import Any

from huske.sync.client import SyncError, TranscriptPublisher

_SYNC = "sync"
_STOP = "stop"


class SyncWorker:
    def __init__(
        self,
        publisher: TranscriptPublisher,
        *,
        reconcile_on_start: bool = True,
        retry_cap_seconds: float = 300.0,
    ) -> None:
        self._publisher = publisher
        self._reconcile_on_start = reconcile_on_start
        self._retry_cap = retry_cap_seconds
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

    def _retry_delay(self, attempts: int) -> float:
        return min(self._retry_cap, 2.0 ** min(attempts, 16))

    def _loop(self) -> None:
        if self._reconcile_on_start:
            self._queue.put(_SYNC)
        attempts = 0
        retry_at: float | None = None
        while True:
            if self._stop.is_set() and self._queue.empty():
                return
            wait = 0.25
            if retry_at is not None:
                wait = max(0.0, min(wait, retry_at - time.monotonic()))
            try:
                item = self._queue.get(timeout=wait)
            except queue.Empty:
                if retry_at is None or time.monotonic() < retry_at:
                    continue
                item = _SYNC
            if item == _STOP:
                continue

            # The publisher scans the full transcript tree, so one run covers
            # every notification already queued — and any pending retry.
            retry_at = None
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
                # Permanent failures (bad credentials, missing repository) wait
                # for the next transcript or session instead of hammering Git.
                if exc.retryable and not self._stop.is_set():
                    retry_at = time.monotonic() + self._retry_delay(attempts)
                continue
            except Exception as exc:
                attempts += 1
                self._events.put(
                    {
                        "ok": False,
                        "error": f"sync failed: {exc}",
                        "attempts": attempts,
                        "retryable": True,
                    }
                )
                if not self._stop.is_set():
                    retry_at = time.monotonic() + self._retry_delay(attempts)
                continue

            attempts = 0
            self._events.put(
                {
                    "ok": True,
                    "changed": result.changed,
                    "updated": result.updated,
                    "commit": result.commit,
                    "pushed": result.pushed,
                    "conflicts": list(result.conflicts),
                    "removed_remotely": list(result.removed_remotely),
                    "notes": list(result.notes),
                }
            )


@dataclass(frozen=True)
class SyncNotice:
    """What the session should show for one worker event.

    ``warning`` is the sticky banner text; ``None`` clears it. ``event`` is an
    optional ``(severity, message)`` line for the activity feed.
    """

    warning: str | None
    event: tuple[str, str] | None


class SyncStatus:
    """Turn worker events into a sticky warning plus non-repeating feed lines.

    A Mac that stays offline retries for hours; the banner states the problem
    once and the feed records it once, instead of a line per attempt.
    """

    def __init__(self) -> None:
        self._last_error: str | None = None

    def apply(self, evt: dict[str, Any]) -> SyncNotice:
        feed: tuple[str, str] | None = None
        if not evt.get("ok"):
            error = str(evt.get("error") or "push failed")
            retrying = " — retrying automatically" if evt.get("retryable") else ""
            message = f"Cloud sync: {error}{retrying}"
            if error != self._last_error:
                feed = ("warn", message)
            self._last_error = error
            return SyncNotice(warning=message, event=feed)

        self._last_error = None
        conflicts = list(evt.get("conflicts") or [])
        changed = int(evt.get("changed") or 0)
        if changed:
            updated = int(evt.get("updated") or 0)
            detail = f" ({updated} updated)" if updated else ""
            feed = ("info", f"cloud sync: published {changed} transcript(s){detail}")
        warning: str | None = None
        if conflicts:
            first = conflicts[0]
            more = f" and {len(conflicts) - 1} more" if len(conflicts) > 1 else ""
            warning = (
                f"Cloud sync: {first}{more} was changed in the repository, so Huske "
                "left it as is. Everything else is published."
            )
        return SyncNotice(warning=warning, event=feed)
