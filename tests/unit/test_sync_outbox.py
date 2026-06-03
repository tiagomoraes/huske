"""Outbox: idempotent ack record, failure counting, durability."""

from __future__ import annotations

from pathlib import Path

from huske.sync.outbox import Outbox


def test_mark_and_query(tmp_path: Path) -> None:
    box = Outbox(tmp_path / "outbox.db")
    assert not box.is_sent("2026-06-02/a.md", "hash1")
    box.mark_sent("2026-06-02/a.md", "hash1")
    assert box.is_sent("2026-06-02/a.md", "hash1")
    # Same path, different content hash → not yet sent.
    assert not box.is_sent("2026-06-02/a.md", "hash2")
    box.close()


def test_failures_count_and_clear(tmp_path: Path) -> None:
    box = Outbox(tmp_path / "outbox.db")
    assert box.record_failure("2026-06-02/a.md", "boom") == 1
    assert box.record_failure("2026-06-02/a.md", "boom again") == 2
    assert box.stats()["failing"] == 1
    # A successful send clears the failure row.
    box.mark_sent("2026-06-02/a.md", "hash1")
    assert box.stats()["failing"] == 0
    assert box.stats()["sent"] == 1
    box.close()


def test_durable_across_reopen(tmp_path: Path) -> None:
    db = tmp_path / "outbox.db"
    box = Outbox(db)
    box.mark_sent("2026-06-02/a.md", "hash1")
    box.close()

    reopened = Outbox(db)
    assert reopened.is_sent("2026-06-02/a.md", "hash1")
    reopened.close()
