"""SyncWorker: push, reconcile, and failure handling — with a fake client."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from huske.sync.client import IngestResult, SyncError, sha256_hex
from huske.sync.outbox import Outbox
from huske.sync.worker import SyncWorker


class FakeClient:
    def __init__(self, *, fail_status: int | None = None, fail_count: int = 0) -> None:
        self.pushed: list[tuple[str, str, str]] = []
        self._fail_status = fail_status
        self._fail_count = fail_count

    def push(self, rel: str, content: str, sha: str) -> IngestResult:
        if self._fail_count > 0:
            self._fail_count -= 1
            raise SyncError("boom", status=self._fail_status)
        self.pushed.append((rel, content, sha))
        return IngestResult("stored", rel)


def _write(out: Path, rel: str, content: str) -> Path:
    p = out / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return p


def _wait_event(worker: SyncWorker, pred: Any, timeout: float = 5.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        evt = worker.poll_event(timeout=0.1)
        if evt is not None and pred(evt):
            return evt
    raise AssertionError("timed out waiting for sync event")


def test_worker_pushes_submitted(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    path = _write(out, "2026-06-02/120000_x_001.md", "hello sync")
    box = Outbox(tmp_path / "outbox.db")
    client = FakeClient()
    worker = SyncWorker(out, box, client)  # type: ignore[arg-type]
    worker.start()
    try:
        worker.submit(str(path))
        evt = _wait_event(worker, lambda e: e.get("ok") and not e.get("skipped"))
        assert evt["rel_path"] == "2026-06-02/120000_x_001.md"
        assert client.pushed[0][0] == "2026-06-02/120000_x_001.md"
        assert box.is_sent("2026-06-02/120000_x_001.md", sha256_hex("hello sync"))
    finally:
        worker.stop()
        box.close()


def test_reconcile_enqueues_only_unsent(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    _write(out, "2026-06-02/120000_x_001.md", "first")
    _write(out, "2026-06-02/121500_x_002.md", "second")
    box = Outbox(tmp_path / "outbox.db")
    # Pretend the first was already acknowledged.
    box.mark_sent("2026-06-02/120000_x_001.md", sha256_hex("first"))

    client = FakeClient()
    worker = SyncWorker(out, box, client)  # type: ignore[arg-type]
    assert worker.reconcile() == 1  # only the unsent one is enqueued

    worker.start()
    try:
        _wait_event(worker, lambda e: e.get("ok") and e.get("rel_path") == "2026-06-02/121500_x_002.md")
        pushed_rels = {r for r, _, _ in client.pushed}
        assert pushed_rels == {"2026-06-02/121500_x_002.md"}
    finally:
        worker.stop()
        box.close()


def test_non_retryable_failure_is_recorded_not_retried(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    path = _write(out, "2026-06-02/120000_x_001.md", "payload")
    box = Outbox(tmp_path / "outbox.db")
    client = FakeClient(fail_status=400, fail_count=99)  # 4xx → never retried
    worker = SyncWorker(out, box, client)  # type: ignore[arg-type]
    worker.start()
    try:
        worker.submit(str(path))
        evt = _wait_event(worker, lambda e: not e.get("ok"))
        assert "boom" in evt["error"]
        # Give the loop a beat; a 4xx must not be re-enqueued.
        time.sleep(0.3)
        assert client.pushed == []
        assert box.stats()["failing"] == 1
    finally:
        worker.stop()
        box.close()


def test_outside_output_root_is_skipped(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    out.mkdir(parents=True)
    stray = tmp_path / "elsewhere.md"
    stray.write_text("nope", encoding="utf-8")
    box = Outbox(tmp_path / "outbox.db")
    worker = SyncWorker(out, box, FakeClient())  # type: ignore[arg-type]
    worker.start()
    try:
        worker.submit(str(stray))
        evt = _wait_event(worker, lambda e: not e.get("ok"))
        assert "outside output_root" in evt["error"]
    finally:
        worker.stop()
        box.close()
