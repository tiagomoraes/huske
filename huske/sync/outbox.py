"""Durable send-outbox: which transcripts the huske server has acknowledged.

A persisted Transcript is immutable, so the unit of truth is
``(rel_path, content_hash)``: once the server acks that pair we never re-send
it. If a Mac records while offline, the rows simply aren't there yet and the
next reconcile picks them up. Stdlib ``sqlite3`` only — no extra deps.
"""

from __future__ import annotations

import sqlite3
import threading
from datetime import UTC, datetime
from pathlib import Path


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class Outbox:
    """Thread-safe record of acknowledged sends, backed by a single sqlite file."""

    def __init__(self, db_path: Path) -> None:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        # check_same_thread=False: the SyncWorker thread writes while the main
        # thread may read during reconcile; every access holds ``_lock``.
        self._conn = sqlite3.connect(str(db_path), check_same_thread=False)
        self._lock = threading.Lock()
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS sent ("
            "rel_path TEXT PRIMARY KEY, content_hash TEXT NOT NULL, sent_at TEXT NOT NULL)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS failures ("
            "rel_path TEXT PRIMARY KEY, attempts INTEGER NOT NULL, "
            "last_error TEXT, updated_at TEXT NOT NULL)"
        )
        self._conn.commit()

    def is_sent(self, rel_path: str, content_hash: str) -> bool:
        with self._lock:
            row = self._conn.execute(
                "SELECT 1 FROM sent WHERE rel_path=? AND content_hash=?",
                (rel_path, content_hash),
            ).fetchone()
        return row is not None

    def mark_sent(self, rel_path: str, content_hash: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO sent(rel_path, content_hash, sent_at) VALUES (?,?,?)",
                (rel_path, content_hash, _now()),
            )
            self._conn.execute("DELETE FROM failures WHERE rel_path=?", (rel_path,))
            self._conn.commit()

    def record_failure(self, rel_path: str, error: str) -> int:
        """Bump the attempt counter for ``rel_path``; return the new count."""
        with self._lock:
            row = self._conn.execute(
                "SELECT attempts FROM failures WHERE rel_path=?", (rel_path,)
            ).fetchone()
            attempts = (int(row[0]) if row else 0) + 1
            self._conn.execute(
                "INSERT OR REPLACE INTO failures(rel_path, attempts, last_error, updated_at) "
                "VALUES (?,?,?,?)",
                (rel_path, attempts, error[:500], _now()),
            )
            self._conn.commit()
        return attempts

    def stats(self) -> dict[str, int]:
        with self._lock:
            sent = self._conn.execute("SELECT count(*) FROM sent").fetchone()[0]
            failing = self._conn.execute("SELECT count(*) FROM failures").fetchone()[0]
        return {"sent": int(sent), "failing": int(failing)}

    def close(self) -> None:
        with self._lock:
            self._conn.close()
