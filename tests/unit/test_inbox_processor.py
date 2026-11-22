"""InboxProcessor end to end, over the real worker loop with a fake engine."""

from __future__ import annotations

import hashlib
import json
import threading
import time
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import yaml

from huske.config import RuntimeConfig
from huske.inbox.processor import InboxProcessor, is_inbox_job_id
from huske.inbox.store import InboxStore, parse_timestamp
from huske.models import RenderState, Transcript
from huske.transcribe.writer import render_transcript

from ._inbox_fakes import (
    FakeEngine,
    InlineWorker,
    install_fake_asr,
    make_cfg,
    silence,
    tone,
    worker_factory,
    write_wav,
)

STARTED = "2026-11-19T14:03:00-03:00"


def _frontmatter(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    return dict(yaml.safe_load(text.split("---\n")[1]))


def _speech_clip(tmp_path: Path) -> Path:
    # 150 s: speech with short pauses — three ≤ 60 s pieces at chunk_minutes=1.
    parts = []
    for i in range(10):
        parts += [tone(13.0, freq=200.0 + 20 * i), silence(2.0)]
    return write_wav(tmp_path / "src" / "meeting.wav", np.concatenate(parts))


def _add(store: InboxStore, clip: Path, item_id: str = "4E1C0A5B", **kw: Any) -> None:
    kw.setdefault("title", "Reunião com a Ana")
    kw.setdefault("device", "iPhone de Tiago")
    kw.setdefault("origin", "phone")
    kw.setdefault("started_at", parse_timestamp(STARTED))
    store.add(clip, item_id=item_id, **kw)


@pytest.fixture
def engine(monkeypatch: pytest.MonkeyPatch) -> FakeEngine:
    eng = FakeEngine()
    install_fake_asr(monkeypatch, eng)
    return eng


def _one_shot(cfg: RuntimeConfig, workers: list[InlineWorker] | None = None) -> InboxProcessor:
    proc = InboxProcessor(cfg, background=False)
    assert proc.try_acquire()
    try:
        proc.run_pending(worker_factory(workers if workers is not None else []))
    finally:
        proc.release()
    return proc


# ---------------------------------------------------------------------------
# One-shot (`huske inbox process`)
# ---------------------------------------------------------------------------


def test_one_shot_writes_deterministic_transcripts_with_import_frontmatter(
    tmp_path: Path, engine: FakeEngine
) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _speech_clip(tmp_path))
    workers: list[InlineWorker] = []

    _one_shot(cfg, workers)

    item = store.get("4E1C0A5B")
    assert item is not None
    status = item.status
    assert status["state"] == "done"
    assert status["attempts"] == 1
    assert status["chunks_total"] == status["chunks_done"] == 3
    assert status["error"] is None

    started = parse_timestamp(STARTED).astimezone()
    sid8 = hashlib.sha1(b"4E1C0A5B").hexdigest()[:8]
    assert status["session_id"] == f"{started.strftime('%Y%m%dT%H%M%S')}_{sid8}"
    paths = [Path(p) for p in status["transcripts"]]
    assert len(paths) == 3
    assert all(p.is_absolute() and p.exists() for p in paths)
    assert paths[0] == (
        cfg.output_root / started.date().isoformat() / f"{started.strftime('%H%M%S')}_{sid8}_001.md"
    )
    assert [p.name.rsplit("_", 1)[1] for p in paths] == ["001.md", "002.md", "003.md"]

    fm = _frontmatter(paths[1])
    assert fm["session_id"] == status["session_id"]
    assert fm["chunk_seq"] == 2
    assert fm["audio_sources"] == ["microphone"]
    assert fm["model"] == "fake:test"
    assert fm["incomplete"] is False
    assert fm["origin"] == "phone"
    assert fm["device"] == "iPhone de Tiago"
    assert fm["title"] == "Reunião com a Ana"
    assert fm["import_id"] == "4E1C0A5B"
    # start_time = started_at + piece offset; pieces are ≤ chunk_minutes.
    t1 = datetime.fromisoformat(str(fm["start_time"]))
    assert 45 <= (t1 - started).total_seconds() <= 60
    assert all(_frontmatter(p)["duration_seconds"] <= 60 for p in paths)
    # Additive keys come after every core key, in contract order.
    keys = list(fm)
    assert keys[keys.index("huske_version") + 1 :] == ["origin", "device", "title", "import_id"]

    # Retention: original deleted, metadata kept, scratch gone, worker stopped.
    assert not item.audio_path.exists()
    assert (item.dir / "recording.json").exists()
    assert not (item.dir / "work").exists()
    assert len(workers) == 1 and not workers[0].alive
    # Jobs never ask for echo handling and carry the routing id.
    assert all(j["echo_cancel"] is False and is_inbox_job_id(j["job_id"]) for j in workers[0].submitted)


def test_nothing_queued_never_starts_a_worker(tmp_path: Path, engine: FakeEngine) -> None:
    workers: list[InlineWorker] = []
    _one_shot(make_cfg(tmp_path), workers)
    assert workers == []


def test_keep_audio_moves_the_original_under_audio_root(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path, keep_audio=True)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "a.wav", tone(5.0)), item_id="keep-me")

    _one_shot(cfg)

    started = parse_timestamp(STARTED).astimezone()
    kept = cfg.audio_root / "imported" / started.date().isoformat() / "keep-me.wav"
    assert kept.exists()
    item = store.get("keep-me")
    assert item is not None and item.state == "done"
    assert not item.audio_path.exists()


def test_retry_rewrites_the_same_files(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path, keep_audio=True)
    store = InboxStore(cfg.inbox_root)
    clip = _speech_clip(tmp_path)
    _add(store, clip)
    _one_shot(cfg)
    first = sorted(cfg.output_root.rglob("*.md"))

    # Re-run the same item from scratch (e.g. an interrupted earlier attempt).
    item = store.get("4E1C0A5B")
    assert item is not None
    item.audio_path.write_bytes(clip.read_bytes())
    store.write_status(item, state="queued")
    _one_shot(cfg)

    second = sorted(p for p in cfg.output_root.rglob("*.md") if p.name != "README.md")
    assert [p.name for p in second] == [p.name for p in first if p.name != "README.md"]
    assert not [p for p in second if p.stem.count("_") > 2]  # no disambiguated copies


def test_silent_recording_is_done_with_no_transcripts(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "quiet.wav", silence(4.0)), item_id="quiet")
    _one_shot(cfg)
    item = store.get("quiet")
    assert item is not None
    assert item.state == "done"
    assert item.status["transcripts"] == []
    assert item.status["chunks_done"] == 1


def test_failure_then_automatic_retry(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    install_fake_asr(monkeypatch, FakeEngine(fail_times=1))
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "a.wav", tone(3.0)), item_id="flaky")

    _one_shot(cfg)
    item = store.get("flaky")
    assert item is not None
    assert item.state == "failed"
    assert item.attempts == 1
    assert "synthetic engine failure" in item.status["error"]
    assert item.audio_path.exists()  # kept for the retry

    _one_shot(cfg)  # a later pass retries it
    item = store.get("flaky")
    assert item is not None
    assert item.state == "done"
    assert item.attempts == 2
    assert item.status["error"] is None


def test_gives_up_after_three_attempts(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    install_fake_asr(monkeypatch, FakeEngine(fail_times=99))
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "a.wav", tone(3.0)), item_id="doomed")

    for _ in range(4):
        _one_shot(cfg)

    item = store.get("doomed")
    assert item is not None
    assert item.state == "failed" and item.attempts == 3
    assert InboxProcessor(cfg).next_runnable() is None


def test_undecodable_file_fails_without_a_worker(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"RIFF....not really")
    store.add(bad, item_id="bad", started_at=parse_timestamp(STARTED))
    workers: list[InlineWorker] = []

    _one_shot(cfg, workers)

    item = store.get("bad")
    assert item is not None
    assert item.state == "failed"
    assert item.status["error"].startswith("could not decode")
    assert workers == []


# ---------------------------------------------------------------------------
# Lock exclusivity, interruption, abandon
# ---------------------------------------------------------------------------


def test_second_processor_defers_to_the_lock_holder(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "a.wav", tone(3.0)))
    holder = InboxProcessor(cfg)
    other = InboxProcessor(cfg)
    assert holder.try_acquire()
    try:
        assert not other.try_acquire()
        assert other.poll(force=True) == []
        item = store.get("4E1C0A5B")
        assert item is not None and item.state == "queued"  # untouched
    finally:
        holder.release()
    assert other.try_acquire()
    other.release()


def test_items_left_processing_by_a_dead_holder_are_requeued(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    clip = write_wav(tmp_path / "a.wav", tone(3.0))
    for item_id, attempts in [("crashed-once", 1), ("crash-loop", 3)]:
        store.add(clip, item_id=item_id)
        item = store.get(item_id)
        assert item is not None
        store.write_status(item, state="processing", attempts=attempts)
        (item.dir / "work").mkdir()

    proc = InboxProcessor(cfg)
    assert proc.try_acquire()
    proc.release()

    once = store.get("crashed-once")
    loop = store.get("crash-loop")
    assert once is not None and loop is not None
    assert once.state == "queued" and once.attempts == 1  # the crash counted
    assert not (once.dir / "work").exists()
    assert loop.state == "failed"


def test_abandon_requeues_without_spending_an_attempt(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _speech_clip(tmp_path))
    proc = InboxProcessor(cfg, background=False)
    assert proc.try_acquire()
    jobs = proc.poll(force=True)
    assert len(jobs) == 1 and jobs[0]["chunk_seq"] == 1
    item = store.get("4E1C0A5B")
    assert item is not None and item.state == "processing" and item.attempts == 1

    proc.release()  # graceful stop mid-item

    item = store.get("4E1C0A5B")
    assert item is not None
    assert item.state == "queued" and item.attempts == 0
    assert item.audio_path.exists()
    assert not (item.dir / "work").exists()
    # A late result for the abandoned job is ignored.
    assert proc.handle_result({"job_id": jobs[0]["job_id"], "chunk_seq": 1, "ok": True}) == []


def test_lost_worker_fails_the_item(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "a.wav", tone(3.0)))
    now = [100.0]
    proc = InboxProcessor(cfg, background=False, clock=lambda: now[0])
    assert proc.try_acquire()
    job = proc.poll(force=True)[0]

    assert proc.check_worker(alive=False) == []  # not submitted yet: fine
    proc.mark_submitted(job["job_id"])
    assert proc.check_worker(alive=True) == []
    assert proc.check_worker(alive=False) == []  # grace period starts
    now[0] += 5.0
    assert proc.check_worker(alive=False) == [job["job_id"]]

    item = store.get("4E1C0A5B")
    assert item is not None
    assert item.state == "failed" and "worker exited" in item.status["error"]
    proc.release()


# ---------------------------------------------------------------------------
# Live-engine mode (background preparation, one piece in flight)
# ---------------------------------------------------------------------------


def _drive_live(
    proc: InboxProcessor, worker: InlineWorker, *, until: Callable[[], bool], timeout: float = 20.0
) -> list[Path]:
    """Mimic run_loop: poll → backlog → submit → route results."""
    written: list[Path] = []
    in_flight = 0
    max_in_flight = 0
    deadline = time.monotonic() + timeout
    while not until():
        assert time.monotonic() < deadline, "live inbox did not finish"
        for job in proc.poll():
            worker.submit(job)
            proc.mark_submitted(job["job_id"])
            in_flight += 1
            max_in_flight = max(max_in_flight, in_flight)
        result = worker.poll_result(timeout=0.02)
        if result is not None and is_inbox_job_id(result.get("job_id")):
            in_flight -= 1
            written += proc.handle_result(result)
    assert max_in_flight <= 1
    return written


def test_live_mode_prepares_in_background_and_feeds_one_piece_at_a_time(
    tmp_path: Path, engine: FakeEngine
) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    events: list[tuple[str, str]] = []
    proc = InboxProcessor(
        cfg, background=True, scan_interval=0.0, on_event=lambda s, m: events.append((s, m))
    )
    assert proc.try_acquire()
    worker = InlineWorker()
    worker.start()
    try:
        assert proc.poll() == []  # nothing queued yet
        _add(store, _speech_clip(tmp_path))
        written = _drive_live(
            proc,
            worker,
            until=lambda: (i := store.get("4E1C0A5B")) is not None and i.state == "done",
        )
    finally:
        worker.stop()
        proc.release()

    item = store.get("4E1C0A5B")
    assert item is not None
    assert [str(p) for p in written] == item.status["transcripts"]
    assert len(written) == 3
    assert any("transcribing Reunião com a Ana" in m for _, m in events)


def test_main_loop_routes_inbox_results_away_from_live_accounting() -> None:
    """A colliding chunk_seq from an import must not clear a live chunk."""
    from huske import run_loop

    live_seen: list[int] = []
    routed: list[dict[str, Any]] = []
    written: list[Path] = []
    results = [
        {"job_id": "inbox:rec:1", "chunk_seq": 1, "ok": True, "transcript_path": "/t/a.md"},
        {"chunk_seq": 1, "ok": True, "transcript_path": "/t/live.md"},
    ]

    class FakeWorker:
        queue_depth = 0

        def poll_result(self, timeout: float = 0.0) -> dict[str, Any] | None:
            return results.pop(0) if results else None

    class FakeCapture:
        last_callback_at = None
        mic_last_callback_at = None
        mic_active = False

        def peak_levels_db(self) -> tuple[float, float]:
            return (-120.0, -120.0)

    class FakeRotator:
        current_chunk_seq = 0
        chunk_started_at = None
        next_rotation_at = None

    stop = threading.Event()

    def route(result: dict[str, Any]) -> bool:
        if is_inbox_job_id(result.get("job_id")):
            routed.append(result)
            return True
        return False

    def on_tick() -> None:
        if not results:
            stop.set()

    run_loop._main_loop(
        RuntimeConfig(),
        RenderState(),
        FakeRotator(),  # type: ignore[arg-type]
        FakeCapture(),  # type: ignore[arg-type]
        FakeWorker(),  # type: ignore[arg-type]
        stop,
        log=type("L", (), {"debug": lambda *a, **k: None, "info": lambda *a, **k: None})(),
        on_result=live_seen.append,
        on_written=written.append,
        on_tick=on_tick,
        route_result=route,
    )

    assert [r["job_id"] for r in routed] == ["inbox:rec:1"]
    assert live_seen == [1]  # only the live result reached live accounting
    assert written == [Path("/t/live.md")]


# ---------------------------------------------------------------------------
# Writer: additive frontmatter, live output unchanged
# ---------------------------------------------------------------------------


def _transcript(**extra: Any) -> Transcript:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    return Transcript(
        session_id="20260507T091500_8a3f2c19",
        chunk_seq=2,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="parakeet:tdt-0.6b-v3",
        language="pt",
        incomplete=False,
        body="[09:30:00 · mic] Oi.",
        huske_version="0.5.0",
        **extra,
    )


def test_live_transcripts_render_exactly_as_before() -> None:
    rendered = render_transcript(_transcript())
    fm = rendered.split("---\n")[1]
    assert fm.rstrip("\n").splitlines()[-1] == "huske_version: 0.5.0"
    for key in ("origin", "device", "title", "import_id"):
        assert f"\n{key}:" not in rendered


def test_extra_frontmatter_is_additive_and_cannot_shadow_core_keys() -> None:
    rendered = render_transcript(
        _transcript(
            extra_frontmatter={
                "origin": "phone",
                "device": "",
                "title": "Reunião: com a Ana",
                "import_id": "4E1C",
                "session_id": "hijack",
            }
        )
    )
    fm = yaml.safe_load(rendered.split("---\n")[1])
    assert fm["session_id"] == "20260507T091500_8a3f2c19"
    assert list(fm)[-3:] == ["origin", "title", "import_id"]  # empty device dropped
    assert fm["title"] == "Reunião: com a Ana"


def test_worker_echoes_job_id_on_failure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    install_fake_asr(monkeypatch, FakeEngine())
    worker = InlineWorker()
    worker.start()
    try:
        worker.submit({"job_id": "inbox:x:1", "chunk_seq": 1, "audio_paths": {"microphone": "/nope.wav"},
                       "config_model": "base", "language": None})
        result = worker.poll_result(timeout=5.0)
    finally:
        worker.stop()
    assert result is not None
    assert result["ok"] is False and result["job_id"] == "inbox:x:1"


def test_status_json_is_what_the_app_reads(tmp_path: Path, engine: FakeEngine) -> None:
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, write_wav(tmp_path / "a.wav", tone(3.0)))
    _one_shot(cfg)
    status = json.loads((cfg.inbox_root / "4E1C0A5B" / "status.json").read_text())
    assert set(status) == {
        "id", "state", "updated_at", "attempts", "chunks_total", "chunks_done",
        "session_id", "transcripts", "error",
    }


def test_done_item_with_leftover_audio_is_cleaned_on_prune(tmp_path) -> None:
    """A crash after `done` but before the audio cleanup must not leak audio."""
    from huske.config import RuntimeConfig
    from huske.inbox.processor import InboxProcessor
    from huske.inbox.store import InboxStore

    from ._inbox_fakes import tone, write_wav

    cfg = RuntimeConfig(
        output_root=tmp_path / "t", audio_root=tmp_path / "a", logs_root=tmp_path / "l",
        inbox_root=tmp_path / "inbox",
    )
    store = InboxStore(cfg.inbox_root)
    clip = write_wav(tmp_path / "c.wav", tone(1.0))
    item, _ = store.add(clip, item_id="left", origin="file")
    store.write_status(item, state="done", transcripts=[])
    assert item.audio_path.is_file()
    proc = InboxProcessor(cfg, background=False)
    assert proc.try_acquire()
    try:
        assert not store.get("left").audio_path.is_file()  # type: ignore[union-attr]
    finally:
        proc.release()
