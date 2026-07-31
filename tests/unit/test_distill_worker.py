"""DistillWorker thread: live submit, sidecar handoff, skip, reconcile.

Uses HeuristicDistiller — no LLM daemon, fully deterministic.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from huske.distill.distiller import HeuristicDistiller
from huske.distill.sidecar import read_sidecar
from huske.distill.worker import DistillWorker
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _write_transcript(day_dir: Path, seq: int = 1) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {"start": 0.0, "end": 3.0, "text": "We ship on Friday. Budget approved.", "source": "system"},
        {"start": 4.0, "end": 5.0, "text": "I will send the deck.", "source": "microphone"},
    ]
    body = body_from_source_segments(start, segs)
    t = build_transcript_from_segments(
        session_id="20260507T093000_8a3f2c19",
        chunk_seq=seq,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="en",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day_dir.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day_dir / f"093000_8a3f2c19_{seq:03d}.md")


def _wait(worker: DistillWorker, predicate: Callable[[dict[str, Any]], bool], timeout: float = 10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        evt = worker.poll_event(timeout=0.2)
        if evt is not None and predicate(evt):
            return evt
    raise AssertionError("timed out waiting for distill event")


def test_worker_distills_transcript(tmp_path: Path) -> None:
    transcript = _write_transcript(tmp_path / "transcripts" / "2026-05-07")
    worker = DistillWorker(
        tmp_path / "transcripts",
        HeuristicDistiller(),
    )
    worker.start()
    try:
        worker.submit(str(transcript))
        evt = _wait(worker, lambda e: e.get("path") == str(transcript) and "statements" in e)
        assert evt["ok"] is True
        assert evt["statements"] >= 1
    finally:
        worker.stop(drain_timeout=5.0)

    sidecar = read_sidecar(transcript)
    assert sidecar is not None and sidecar.statements


def test_worker_skips_when_sidecar_current(tmp_path: Path) -> None:
    transcript = _write_transcript(tmp_path / "transcripts" / "2026-05-07")
    worker = DistillWorker(tmp_path / "transcripts", HeuristicDistiller())
    worker.start()
    try:
        worker.submit(str(transcript))
        _wait(worker, lambda e: e.get("path") == str(transcript) and not e.get("skipped"))
        # Re-submit the same (unchanged) transcript — second pass is a skip.
        worker.submit(str(transcript))
        evt = _wait(worker, lambda e: e.get("path") == str(transcript) and e.get("skipped"))
        assert evt["ok"] is True
        assert evt["skipped"] is True
    finally:
        worker.stop(drain_timeout=5.0)


def test_reconcile_enqueues_undistilled(tmp_path: Path) -> None:
    _write_transcript(tmp_path / "transcripts" / "2026-05-07", seq=1)
    _write_transcript(tmp_path / "transcripts" / "2026-05-07", seq=2)
    worker = DistillWorker(tmp_path / "transcripts", HeuristicDistiller())
    assert worker.reconcile() == 2  # both lack sidecars
    worker.start()
    try:
        # Drain both, then reconcile again — now both are current → nothing enqueued.
        _wait(worker, lambda e: e.get("path", "").endswith("_001.md"))
        _wait(worker, lambda e: e.get("path", "").endswith("_002.md"))
    finally:
        worker.stop(drain_timeout=5.0)
    assert worker.reconcile() == 0
