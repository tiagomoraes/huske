"""`chunk_progress`: an estimate of how far the piece in flight has got.

A long recording is cut into pieces of at most ``chunk_minutes``; with only
``chunks_done / chunks_total`` to go on, the phone showed "Transcribing ·
1 of 3" for minutes per piece and looked stuck. The ASR call itself reports
nothing (``mlx_whisper`` is one opaque call), so the engine estimates from
elapsed time and the speed it has *measured* on this Mac — and says nothing
until it has measured one.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np

from huske.inbox.processor import (
    MIN_MEASURED_AUDIO_SECONDS,
    PROGRESS_INTERVAL_SECONDS,
    InboxProcessor,
    Throughput,
    estimate_piece_progress,
)
from huske.inbox.store import THROUGHPUT_FILE, InboxStore, parse_timestamp

from ._inbox_fakes import make_cfg, silence, tone, write_wav

STARTED = "2026-11-19T14:03:00-03:00"


# --- the curve ---------------------------------------------------------------


def test_the_estimate_rises_to_ninety_percent_at_the_expected_time() -> None:
    assert estimate_piece_progress(0.0, 100.0) == 0.0
    assert estimate_piece_progress(50.0, 100.0) == 0.45
    assert estimate_piece_progress(100.0, 100.0) == 0.9


def test_the_estimate_only_grows_and_never_says_done() -> None:
    values = [estimate_piece_progress(float(t), 100.0) for t in range(0, 20_000, 7)]
    assert all(v is not None for v in values)
    numbers = [v for v in values if v is not None]
    assert numbers == sorted(numbers), "went backwards"
    # However late the piece runs: done is the result arriving, not a guess.
    assert max(numbers) <= 0.99
    late = estimate_piece_progress(1_000_000.0, 100.0)
    assert late is not None and 0.98 < late <= 0.99 < 1.0


def test_no_estimate_without_an_expectation() -> None:
    assert estimate_piece_progress(10.0, 0.0) is None
    assert estimate_piece_progress(10.0, -1.0) is None
    assert estimate_piece_progress(-1.0, 100.0) is None


# --- measured speed ----------------------------------------------------------


def test_speed_is_unknown_until_a_piece_was_measured(tmp_path: Path) -> None:
    speed = Throughput(tmp_path / THROUGHPUT_FILE, "whisper:large-v3-turbo")
    assert speed.rate() is None
    assert not (tmp_path / THROUGHPUT_FILE).exists()


def test_speed_is_measured_kept_and_read_back_by_a_later_pass(tmp_path: Path) -> None:
    path = tmp_path / THROUGHPUT_FILE
    speed = Throughput(path, "whisper:large-v3-turbo")

    speed.record(wall_seconds=300.0, audio_seconds=600.0)

    assert speed.rate() == 0.5
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert stored["version"] == 1
    assert stored["engines"]["whisper:large-v3-turbo"] == {
        "wall_seconds": 300.0,
        "audio_seconds": 600.0,
    }
    # The next `huske inbox process` starts with it, so even its first piece
    # has an estimate.
    assert Throughput(path, "whisper:large-v3-turbo").rate() == 0.5
    # A different engine or model is a different speed: unknown.
    assert Throughput(path, "parakeet:mlx-community/parakeet-tdt-0.6b-v3").rate() is None


def test_speed_is_per_engine_and_other_entries_survive(tmp_path: Path) -> None:
    path = tmp_path / THROUGHPUT_FILE
    Throughput(path, "whisper:base").record(60.0, 600.0)
    Throughput(path, "parakeet:tdt").record(12.0, 600.0)

    assert Throughput(path, "whisper:base").rate() == 0.1
    assert Throughput(path, "parakeet:tdt").rate() == 0.02


def test_recent_pieces_weigh_more(tmp_path: Path) -> None:
    speed = Throughput(tmp_path / THROUGHPUT_FILE, "whisper:base")
    speed.record(600.0, 600.0)  # a slow day: 1.0
    speed.record(60.0, 600.0)  # now 0.1
    rate = speed.rate()
    assert rate is not None
    assert 0.1 < rate < 0.55  # nearer the recent one than the plain average


def test_short_pieces_do_not_feed_the_measurement(tmp_path: Path) -> None:
    # A 10 s clip is mostly model load; it says nothing about a 10 min piece.
    speed = Throughput(tmp_path / THROUGHPUT_FILE, "whisper:base")
    speed.record(wall_seconds=9.0, audio_seconds=MIN_MEASURED_AUDIO_SECONDS - 1)
    assert speed.rate() is None
    speed.record(wall_seconds=0.0, audio_seconds=600.0)
    assert speed.rate() is None


def test_an_unreadable_speed_file_is_ignored_then_replaced(tmp_path: Path) -> None:
    path = tmp_path / THROUGHPUT_FILE
    path.write_text("{ not json", encoding="utf-8")
    speed = Throughput(path, "whisper:base")
    assert speed.rate() is None
    speed.record(60.0, 600.0)
    assert Throughput(path, "whisper:base").rate() == 0.1


# --- status.json -------------------------------------------------------------


def _clip(tmp_path: Path) -> Path:
    parts = []
    for i in range(10):  # 150 s → three ≤ 60 s pieces at chunk_minutes=1
        parts += [tone(13.0, freq=200.0 + 20 * i), silence(2.0)]
    return write_wav(tmp_path / "src" / "long.wav", np.concatenate(parts))


def _status(cfg: Any, item_id: str) -> dict[str, Any]:
    status: dict[str, Any] = json.loads(
        (cfg.inbox_root / item_id / "status.json").read_text(encoding="utf-8")
    )
    return status


class _Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def _begin(tmp_path: Path, clock: _Clock) -> tuple[Any, InboxProcessor, dict[str, Any]]:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    store.add(_clip(tmp_path), item_id="phone-a", started_at=parse_timestamp(STARTED))
    processor = InboxProcessor(cfg, background=False, store=store, clock=clock)
    assert processor.try_acquire()
    jobs = processor.poll(force=True)
    assert len(jobs) == 1
    return cfg, processor, jobs[0]


def test_any_other_status_write_drops_the_transient_progress(tmp_path: Path) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    item, _ = store.add(write_wav(tmp_path / "a.wav", tone(2.0)), item_id="phone-a")

    store.write_status(item, state="processing", chunk_progress=0.4)
    assert _status(cfg, "phone-a")["chunk_progress"] == 0.4

    store.write_status(item, chunks_done=1)
    assert "chunk_progress" not in _status(cfg, "phone-a")
    assert "chunk_progress" not in item.status


def test_the_piece_in_flight_reports_progress_from_the_measured_speed(tmp_path: Path) -> None:
    clock = _Clock()
    cfg = make_cfg(tmp_path)
    cfg.inbox_root.mkdir(parents=True, exist_ok=True)
    # Measured on an earlier pass: half a second of work per second of audio.
    Throughput(cfg.inbox_root / THROUGHPUT_FILE, f"{cfg.asr_engine}:{cfg.parakeet_model}").record(
        300.0, 600.0
    )
    cfg, processor, job = _begin(tmp_path, clock)
    try:
        seconds = float(job["actual_duration_seconds"])
        expected = seconds * 0.5
        assert _status(cfg, "phone-a")["chunks_total"] == 3
        assert "chunk_progress" not in _status(cfg, "phone-a"), "nothing before it is submitted"

        processor.mark_submitted(job["job_id"])
        seen: list[float] = []
        for _ in range(40):  # far past the expected time: a piece that runs late
            clock.now += PROGRESS_INTERVAL_SECONDS
            assert processor.poll() == []
            status = _status(cfg, "phone-a")
            assert status["state"] == "processing" and status["chunks_done"] == 0
            seen.append(status["chunk_progress"])

        assert seen[0] == int(0.9 * PROGRESS_INTERVAL_SECONDS / expected * 100) / 100
        assert seen == sorted(seen), "progress went backwards"
        assert 0.9 <= max(seen) <= 0.99, "an estimate never says the piece is done"

        # The result arriving is what completes the piece.
        clock.now += 1.0
        processor.handle_result(
            {"job_id": job["job_id"], "ok": True, "chunk_seq": 1, "transcript_path": None}
        )
        status = _status(cfg, "phone-a")
        assert status["chunks_done"] == 1
        assert "chunk_progress" not in status, "stale progress left on the next piece"
    finally:
        processor.release()
    assert "chunk_progress" not in _status(cfg, "phone-a")
    assert _status(cfg, "phone-a")["state"] == "queued"


def test_progress_is_not_rewritten_more_often_than_the_interval(tmp_path: Path) -> None:
    clock = _Clock()
    cfg = make_cfg(tmp_path)
    cfg.inbox_root.mkdir(parents=True, exist_ok=True)
    Throughput(cfg.inbox_root / THROUGHPUT_FILE, f"{cfg.asr_engine}:{cfg.parakeet_model}").record(
        300.0, 600.0
    )
    cfg, processor, job = _begin(tmp_path, clock)
    try:
        processor.mark_submitted(job["job_id"])
        clock.now += PROGRESS_INTERVAL_SECONDS
        processor.poll()
        first = _status(cfg, "phone-a")
        for _ in range(8):  # the live engine polls several times a second
            clock.now += 0.125
            processor.poll()
        assert _status(cfg, "phone-a") == first, "status.json rewritten on every poll"
    finally:
        processor.release()


def test_no_progress_is_invented_before_a_piece_was_ever_measured(tmp_path: Path) -> None:
    clock = _Clock()
    cfg, processor, job = _begin(tmp_path, clock)
    try:
        processor.mark_submitted(job["job_id"])
        for _ in range(20):
            clock.now += PROGRESS_INTERVAL_SECONDS
            processor.poll()
            assert "chunk_progress" not in _status(cfg, "phone-a")

        # A piece that produced a transcript is the first measurement…
        clock.now += 20.0
        elapsed = 20 * PROGRESS_INTERVAL_SECONDS + 20.0
        processor.handle_result(
            {
                "job_id": job["job_id"],
                "ok": True,
                "chunk_seq": 1,
                "transcript_path": str(tmp_path / "transcripts" / "one.md"),
            }
        )
        measured = Throughput(
            cfg.inbox_root / THROUGHPUT_FILE, f"{cfg.asr_engine}:{cfg.parakeet_model}"
        ).rate()
        assert measured is not None
        assert abs(measured - elapsed / float(job["actual_duration_seconds"])) < 1e-3

        # …so the next piece of the same recording already has an estimate.
        jobs = processor.poll(force=True)
        assert len(jobs) == 1
        processor.mark_submitted(jobs[0]["job_id"])
        clock.now += PROGRESS_INTERVAL_SECONDS
        processor.poll()
        status = _status(cfg, "phone-a")
        assert status["chunks_done"] == 1
        assert 0.0 < status["chunk_progress"] < 0.9
    finally:
        processor.release()


def test_a_silent_piece_does_not_flatter_the_measurement(tmp_path: Path) -> None:
    clock = _Clock()
    cfg, processor, job = _begin(tmp_path, clock)
    try:
        processor.mark_submitted(job["job_id"])
        clock.now += 0.5  # no speech: the engine returns almost at once
        processor.handle_result(
            {"job_id": job["job_id"], "ok": True, "chunk_seq": 1, "transcript_path": None}
        )
        assert not (cfg.inbox_root / THROUGHPUT_FILE).exists()
    finally:
        processor.release()
