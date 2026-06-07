"""EmbedWorker subprocess: load embedder, index a submitted transcript path."""

from __future__ import annotations

import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.search.store import PassageStore
from huske.search.worker import EmbedWorker
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _write_transcript(day_dir: Path) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {"start": 0.0, "end": 2.0, "text": "discutindo a estratégia de vendas", "source": "system"},
        {"start": 3.0, "end": 4.0, "text": "concordo plenamente", "source": "microphone"},
    ]
    body = body_from_source_segments(start, segs)
    t = build_transcript_from_segments(
        session_id="20260507T093000_8a3f2c19",
        chunk_seq=1,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day_dir.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day_dir / "093000_8a3f2c19_001.md")


def _wait_for(worker: EmbedWorker, predicate, timeout: float = 30.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        msg = worker.poll_result(timeout=0.5)
        if msg is not None and predicate(msg):
            return msg
        if not worker.alive and msg is None:
            raise AssertionError("worker died before predicate matched")
    raise AssertionError("timed out waiting for worker message")


def test_embed_worker_accepts_batch_size() -> None:
    # Construction only (no subprocess): the batch size threads through to the
    # embedder so live indexing honors `embed_batch_size`.
    worker = EmbedWorker("/tmp/does-not-matter.db", "hashing", batch_size=4)
    assert worker._batch_size == 4


def test_embed_worker_indexes_submitted_path(tmp_path: Path) -> None:
    transcript = _write_transcript(tmp_path / "transcripts" / "2026-05-07")
    db_path = tmp_path / "index" / "passages.db"

    worker = EmbedWorker(str(db_path), "hashing")
    worker.start()
    try:
        ready = _wait_for(worker, lambda m: "ready" in m)
        assert ready["ready"] is True, ready

        worker.submit(str(transcript))
        result = _wait_for(worker, lambda m: m.get("path") == str(transcript.resolve()))
        assert result["ok"] is True
        assert result["passages"] >= 1
    finally:
        worker.stop(drain_timeout=5.0)

    # The index is durable and queryable after the worker exits.
    from huske.search.embedder import HashingEmbedder

    emb = HashingEmbedder()
    store = PassageStore.open(db_path, embedding_model="hashing", dim=emb.dim, create=False)
    hits = store.search(emb.embed_query("estratégia de vendas"), k=3)
    assert hits and "estratégia" in hits[0].text
    store.close()


def test_embed_worker_indexes_statements_when_configured(tmp_path: Path) -> None:
    from huske.distill.distiller import HeuristicDistiller, distill_transcript
    from huske.distill.sidecar import write_sidecar
    from huske.search.embedder import HashingEmbedder

    transcript = _write_transcript(tmp_path / "transcripts" / "2026-05-07")
    write_sidecar(transcript, distill_transcript(transcript, HeuristicDistiller()))

    db_path = tmp_path / "index" / "passages.db"
    stmt_db_path = tmp_path / "index" / "statements.db"
    worker = EmbedWorker(str(db_path), "hashing", statements_db_path=str(stmt_db_path))
    worker.start()
    try:
        _wait_for(worker, lambda m: "ready" in m)
        worker.submit(str(transcript))
        result = _wait_for(worker, lambda m: m.get("path") == str(transcript.resolve()))
        assert result["ok"] is True
        assert result["passages"] >= 1
        assert result["statements"] >= 1  # the same embedder embedded the sidecar too
    finally:
        worker.stop(drain_timeout=5.0)

    emb = HashingEmbedder()
    stmt_store = PassageStore.open(
        stmt_db_path, embedding_model="hashing", dim=emb.dim, create=False
    )
    hits = stmt_store.search(emb.embed_query("estratégia de vendas"), k=3)
    assert hits and "estratégia" in hits[0].text
    stmt_store.close()
