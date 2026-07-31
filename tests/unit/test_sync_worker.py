from __future__ import annotations

import time
from typing import Any

from huske.sync.client import SyncError, SyncResult
from huske.sync.worker import SyncWorker


class FakePublisher:
    def __init__(self, failures: int = 0) -> None:
        self.calls = 0
        self.failures = failures

    def sync(self) -> SyncResult:
        self.calls += 1
        if self.calls <= self.failures:
            raise SyncError("offline")
        return SyncResult(changed=2, commit="abc", pushed=True)


def _event(worker: SyncWorker, timeout: float = 5.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        event = worker.poll_event(timeout=0.1)
        if event is not None:
            return event
    raise AssertionError("no worker event")


def test_worker_reconciles_on_start() -> None:
    publisher = FakePublisher()
    worker = SyncWorker(publisher)  # type: ignore[arg-type]
    worker.start()
    try:
        event = _event(worker)
        assert event["ok"]
        assert event["changed"] == 2
        assert publisher.calls == 1
    finally:
        worker.stop()


def test_worker_reports_retryable_failure() -> None:
    publisher = FakePublisher(failures=1)
    worker = SyncWorker(publisher, max_attempts=2)  # type: ignore[arg-type]
    worker.start()
    try:
        event = _event(worker)
        assert not event["ok"]
        assert event["retryable"]
    finally:
        worker.stop()
