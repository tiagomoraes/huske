from __future__ import annotations

import time
from typing import Any

from huske.sync.client import SyncError, SyncResult
from huske.sync.worker import SyncStatus, SyncWorker


class FakePublisher:
    def __init__(
        self,
        failures: int = 0,
        *,
        retryable: bool = True,
        conflicts: tuple[str, ...] = (),
    ) -> None:
        self.calls = 0
        self.failures = failures
        self.retryable = retryable
        self.conflicts = conflicts

    def sync(self) -> SyncResult:
        self.calls += 1
        if self.calls <= self.failures:
            raise SyncError("offline", retryable=self.retryable)
        return SyncResult(
            changed=2, commit="abc", pushed=True, updated=1, conflicts=self.conflicts
        )


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
        assert event["updated"] == 1
        assert publisher.calls == 1
    finally:
        worker.stop()


def test_worker_reports_retryable_failure() -> None:
    publisher = FakePublisher(failures=1)
    worker = SyncWorker(publisher, retry_cap_seconds=0.01)  # type: ignore[arg-type]
    worker.start()
    try:
        event = _event(worker)
        assert not event["ok"]
        assert event["retryable"]
    finally:
        worker.stop()


def test_worker_keeps_retrying_until_the_network_is_back() -> None:
    """The old worker gave up after six attempts (about a minute offline)."""
    publisher = FakePublisher(failures=8)
    worker = SyncWorker(publisher, retry_cap_seconds=0.01)  # type: ignore[arg-type]
    worker.start()
    try:
        failures = [_event(worker) for _ in range(8)]
        assert all(not event["ok"] for event in failures)
        assert _event(worker)["ok"]
        assert publisher.calls == 9
    finally:
        worker.stop()


def test_worker_does_not_retry_permanent_failures_on_its_own() -> None:
    publisher = FakePublisher(failures=5, retryable=False)
    worker = SyncWorker(publisher, retry_cap_seconds=0.01)  # type: ignore[arg-type]
    worker.start()
    try:
        assert not _event(worker)["ok"]
        time.sleep(0.3)
        assert publisher.calls == 1
        worker.submit("new transcript")  # a new transcript tries again
        assert not _event(worker)["ok"]
        assert publisher.calls == 2
    finally:
        worker.stop()


def test_new_transcript_does_not_wait_for_a_pending_backoff() -> None:
    publisher = FakePublisher(failures=1)
    worker = SyncWorker(publisher, retry_cap_seconds=600.0)  # type: ignore[arg-type]
    worker.start()
    try:
        assert not _event(worker)["ok"]  # next retry would be 2 s away
        worker.submit("finalized")
        assert _event(worker, timeout=1.0)["ok"]
    finally:
        worker.stop()


def test_status_shows_one_sticky_warning_and_one_feed_line_per_problem() -> None:
    status = SyncStatus()
    failure = {"ok": False, "error": "can't reach the Git host", "retryable": True}

    first = status.apply(failure)
    assert first.warning == "Cloud sync: can't reach the Git host — retrying automatically"
    assert first.event == ("warn", first.warning)

    repeat = status.apply(failure)
    assert repeat.warning == first.warning
    assert repeat.event is None  # no feed spam while offline for hours

    recovered = status.apply({"ok": True, "changed": 3, "updated": 1})
    assert recovered.warning is None
    assert recovered.event == ("info", "cloud sync: published 3 transcript(s) (1 updated)")

    again = status.apply(failure)
    assert again.event is not None  # a new outage is reported again


def test_status_keeps_a_warning_for_conflicts() -> None:
    notice = SyncStatus().apply(
        {"ok": True, "changed": 0, "conflicts": ["transcripts/a.md", "transcripts/b.md"]}
    )
    assert notice.warning is not None
    assert "transcripts/a.md and 1 more" in notice.warning
