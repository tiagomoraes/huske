"""A recording whose parts do not all transcribe: what is kept, what is redone.

The finished parts of a failed recording stay (their transcripts are listed
in ``status.json`` beside ``missing_chunks``) so Huske.app can hand the phone a
partial transcript, and every later attempt — the automatic ones, a re-queue,
``huske inbox retry`` — transcribes only the parts that have no result yet.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from huske.config import RuntimeConfig
from huske.inbox.processor import InboxProcessor, is_inbox_job_id
from huske.inbox.runner import run_inbox_process, run_inbox_retry
from huske.inbox.store import InboxItem, InboxStore, parse_timestamp

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
ITEM = "4E1C0A5B"


class _FailsOnCalls(FakeEngine):
    """Fails exactly the transcribe calls whose (1-based) number is listed."""

    def __init__(self, fail_calls: set[int]) -> None:
        super().__init__()
        self.fail_calls = set(fail_calls)

    def transcribe(self, audio: np.ndarray) -> list[Any]:
        if self.calls + 1 in self.fail_calls:
            self.calls += 1
            raise RuntimeError("synthetic engine failure")
        return super().transcribe(audio)


def _three_part_clip(tmp_path: Path) -> Path:
    # 150 s of speech with short pauses: three ≤ 60 s pieces at chunk_minutes=1.
    parts = []
    for i in range(10):
        parts += [tone(13.0, freq=200.0 + 20 * i), silence(2.0)]
    return write_wav(tmp_path / "src" / "meeting.wav", np.concatenate(parts))


def _add(store: InboxStore, clip: Path) -> None:
    store.add(
        clip,
        item_id=ITEM,
        title="Reunião com a Ana",
        origin="phone",
        started_at=parse_timestamp(STARTED),
    )


def _one_shot(cfg: RuntimeConfig, **kwargs: Any) -> InboxProcessor:
    proc = InboxProcessor(cfg, background=False, **kwargs)
    assert proc.try_acquire()
    try:
        proc.run_pending(worker_factory([]))
    finally:
        proc.release()
    return proc


def _item(store: InboxStore) -> InboxItem:
    item = store.get(ITEM)
    assert item is not None
    return item


def _seqs(paths: list[str]) -> list[str]:
    return [Path(p).stem.rsplit("_", 1)[-1] for p in paths]


def _fail_part_two_for_good(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[RuntimeConfig, InboxStore, _FailsOnCalls]:
    """Three passes over a three-part recording whose part 2 never transcribes."""
    # Attempt 1 transcribes parts 1, 2, 3 (calls 1-3); attempts 2 and 3 only
    # part 2 again (calls 4 and 5).
    engine = _FailsOnCalls({2, 4, 5})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    for _ in range(3):
        _one_shot(cfg)
    return cfg, store, engine


def test_a_failed_part_does_not_stop_the_others_and_is_recorded_as_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))

    _one_shot(cfg)

    item = _item(store)
    assert item.state == "failed" and item.attempts == 1
    assert engine.calls == 3  # part 3 was still transcribed
    assert item.status["chunks_total"] == 3
    assert item.status["chunks_done"] == 2
    assert item.status["missing_chunks"] == [2]
    assert _seqs(item.status["transcripts"]) == ["001", "003"]
    assert all(Path(p).is_file() for p in item.status["transcripts"])
    assert item.status["error"] == "chunk 2/3 failed: synthetic engine failure"
    assert item.audio_path.exists()  # kept: the missing part needs it


def test_an_automatic_retry_transcribes_only_the_missing_part(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    _one_shot(cfg)
    kept = {p: Path(p).stat().st_mtime_ns for p in _item(store).status["transcripts"]}

    _one_shot(cfg)  # the next pass retries it

    item = _item(store)
    assert item.state == "done" and item.attempts == 2
    assert engine.calls == 4  # one more call: part 2 only
    assert _seqs(item.status["transcripts"]) == ["001", "002", "003"]
    assert item.status["chunks_done"] == 3
    assert "missing_chunks" not in item.status
    assert "chunk_results" not in item.status
    # The parts that were already there were not written again.
    assert {p: Path(p).stat().st_mtime_ns for p in kept} == kept
    assert not item.audio_path.exists()


def test_a_recording_that_fails_for_good_keeps_its_finished_parts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg, store, engine = _fail_part_two_for_good(tmp_path, monkeypatch)

    item = _item(store)
    assert item.state == "failed" and item.attempts == 3
    assert engine.calls == 5  # 3 + 1 + 1, never the finished parts again
    assert item.status["missing_chunks"] == [2]
    assert item.status["chunks_total"] == 3 and item.status["chunks_done"] == 2
    assert _seqs(item.status["transcripts"]) == ["001", "003"]
    assert InboxProcessor(cfg).next_runnable() is None


def test_inbox_retry_transcribes_only_the_missing_part_and_completes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg, store, engine = _fail_part_two_for_good(tmp_path, monkeypatch)
    config_path = tmp_path / "config.toml"
    config_path.write_text(
        "\n".join(
            f'{key} = "{getattr(cfg, key)}"'
            for key in ("output_root", "audio_root", "logs_root", "inbox_root")
        )
        + "\nchunk_minutes = 1.0\n",
        encoding="utf-8",
    )
    kept = {p: Path(p).stat().st_mtime_ns for p in _item(store).status["transcripts"]}

    assert run_inbox_retry([ITEM], json_output=True, config_path=config_path) == 0
    retried = json.loads(capsys.readouterr().out)["items"][0]
    assert retried["retried"] is True and retried["state"] == "queued"
    assert retried["attempts"] == 0
    assert "missing_chunks" not in retried

    code = run_inbox_process(
        json_output=True, config_path=config_path, worker_factory=worker_factory([])
    )

    assert code == 0
    item = _item(store)
    assert item.state == "done" and item.attempts == 1
    assert engine.calls == 6  # the retry cost one call: part 2
    assert _seqs(item.status["transcripts"]) == ["001", "002", "003"]
    assert "missing_chunks" not in item.status and "chunk_results" not in item.status
    assert {p: Path(p).stat().st_mtime_ns for p in kept} == kept


def test_a_different_split_starts_over(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    _one_shot(cfg)
    assert _item(store).status["missing_chunks"] == [2]

    # `chunk_minutes` changed: the parts no longer line up with the old ones.
    _one_shot(make_cfg(tmp_path, chunk_minutes=2.0))

    item = _item(store)
    assert item.state == "done"
    assert item.status["chunks_total"] == 2
    assert engine.calls == 3 + 2  # both new parts, none skipped
    assert _seqs(item.status["transcripts"]) == ["001", "002"]


def test_different_asr_settings_start_over(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    _one_shot(cfg)

    # The finished parts were transcribed in another language setting.
    _one_shot(make_cfg(tmp_path, language="pt"))

    item = _item(store)
    assert item.state == "done"
    assert engine.calls == 3 + 3


def test_a_finished_part_whose_transcript_is_gone_is_transcribed_again(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    _one_shot(cfg)
    first = Path(_item(store).status["transcripts"][0])
    first.unlink()

    _one_shot(cfg)

    item = _item(store)
    assert item.state == "done"
    assert engine.calls == 3 + 2  # parts 1 and 2
    assert _seqs(item.status["transcripts"]) == ["001", "002", "003"]
    assert first.is_file()


def _finish_first_part(
    proc: InboxProcessor, worker: InlineWorker
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Transcribe part 1 for real; return its job and the job for part 2."""
    assert proc.try_acquire()
    first = proc.poll(force=True)[0]
    worker.submit(first)
    proc.mark_submitted(first["job_id"])
    result = None
    for _ in range(400):
        result = worker.poll_result(timeout=0.05)
        if result is not None and is_inbox_job_id(result.get("job_id")):
            break
    assert result is not None and result["ok"]
    proc.handle_result(result)
    second = proc.poll(force=True)[0]
    assert second["chunk_seq"] == 2
    return first, second


def test_a_lost_worker_keeps_the_finished_parts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    install_fake_asr(monkeypatch, FakeEngine())
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    now = [100.0]
    proc = InboxProcessor(cfg, background=False, clock=lambda: now[0])
    worker = InlineWorker()
    try:
        _, second = _finish_first_part(proc, worker)
        proc.mark_submitted(second["job_id"])
        assert proc.check_worker(alive=False) == []  # grace period starts
        now[0] += 5.0
        assert proc.check_worker(alive=False) == [second["job_id"]]
    finally:
        worker.stop(drain_timeout=5.0)
        proc.release()

    item = _item(store)
    assert item.state == "failed" and "worker exited" in item.status["error"]
    # Part 2 was in flight and part 3 never reached: both are missing.
    assert item.status["missing_chunks"] == [2, 3]
    assert item.status["chunks_total"] == 3 and item.status["chunks_done"] == 1
    assert _seqs(item.status["transcripts"]) == ["001"]


def test_a_requeued_recording_does_not_transcribe_its_finished_parts_again(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = FakeEngine()
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    proc = InboxProcessor(cfg, background=False)
    worker = InlineWorker()
    try:
        _finish_first_part(proc, worker)
    finally:
        worker.stop(drain_timeout=5.0)
        proc.release()  # a graceful stop with part 2 not yet submitted

    item = _item(store)
    assert item.state == "queued" and item.attempts == 0
    assert item.status["transcripts"] == [] and item.status["chunks_done"] == 0
    assert engine.calls == 1

    _one_shot(cfg)

    item = _item(store)
    assert item.state == "done" and item.attempts == 1
    assert engine.calls == 3  # parts 2 and 3 only
    assert _seqs(item.status["transcripts"]) == ["001", "002", "003"]


def test_a_crash_on_the_last_attempt_still_reports_the_finished_parts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    _one_shot(cfg)
    item = _item(store)
    transcripts = list(item.status["transcripts"])
    # The holder died during the third attempt (as `_start` leaves the status).
    store.write_status(
        item, state="processing", attempts=3, chunks_total=0, chunks_done=0, transcripts=[], error=None
    )

    proc = InboxProcessor(cfg)
    assert proc.try_acquire()  # the next holder recovers it
    proc.release()

    item = _item(store)
    assert item.state == "failed" and item.attempts == 3
    assert item.status["missing_chunks"] == [2]
    assert item.status["chunks_total"] == 3 and item.status["chunks_done"] == 2
    assert item.status["transcripts"] == transcripts


def test_a_decode_failure_on_a_retry_keeps_the_earlier_partial_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    engine = _FailsOnCalls({2})
    install_fake_asr(monkeypatch, engine)
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    _one_shot(cfg)
    transcripts = list(_item(store).status["transcripts"])

    def broken_decoder(*_: Any, **__: Any) -> float:
        raise RuntimeError("afconvert exited 1")

    _one_shot(cfg, decoder=broken_decoder)

    item = _item(store)
    assert item.state == "failed" and item.attempts == 2
    assert item.status["error"] == "could not decode: afconvert exited 1"
    assert item.status["missing_chunks"] == [2]
    assert item.status["transcripts"] == transcripts
    assert item.status["chunks_total"] == 3 and item.status["chunks_done"] == 2


def test_a_recording_with_no_finished_part_lists_every_part_as_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    install_fake_asr(monkeypatch, FakeEngine(fail_times=99))
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))

    _one_shot(cfg)

    item = _item(store)
    assert item.state == "failed"
    assert item.status["missing_chunks"] == [1, 2, 3]
    assert item.status["transcripts"] == [] and item.status["chunks_done"] == 0
    assert item.status["error"].startswith("chunks 1, 2, 3 of 3 failed: ")


def test_a_failed_part_does_not_leave_its_progress_on_the_next_one(tmp_path: Path) -> None:
    from huske.inbox.processor import PROGRESS_INTERVAL_SECONDS, Throughput
    from huske.inbox.store import THROUGHPUT_FILE

    now = [1000.0]
    cfg = make_cfg(tmp_path)
    cfg.inbox_root.mkdir(parents=True, exist_ok=True)
    Throughput(cfg.inbox_root / THROUGHPUT_FILE, f"{cfg.asr_engine}:{cfg.parakeet_model}").record(
        300.0, 600.0
    )
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    proc = InboxProcessor(cfg, background=False, store=store, clock=lambda: now[0])
    assert proc.try_acquire()
    try:
        job = proc.poll(force=True)[0]
        proc.mark_submitted(job["job_id"])
        now[0] += PROGRESS_INTERVAL_SECONDS
        assert proc.poll() == []
        assert _item(store).status["chunk_progress"] > 0

        proc.handle_result({"job_id": job["job_id"], "ok": False, "chunk_seq": 1, "error": "boom"})

        status = _item(store).status
        assert status["state"] == "processing" and status["chunks_done"] == 0
        # Part 2 has not started: nothing of part 1's estimate may be shown for it.
        assert "chunk_progress" not in status
    finally:
        proc.release()


def test_a_decode_cut_short_by_the_stop_itself_is_not_the_recordings_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """SIGTERM reaches the whole process group, afconvert included.

    Huske.app stops a pass by signalling its group, and so does a logout. The
    decoder's `afconvert` dies with the pass and reports a decode error; that
    used to mark the recording `failed` and spend an attempt, where a stop
    must put it back in the queue untouched.
    """
    install_fake_asr(monkeypatch, FakeEngine())
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))
    stopping = [False]

    def killed_with_the_pass(*_: Any, **__: Any) -> float:
        stopping[0] = True  # the signal that stops the pass…
        raise RuntimeError("afconvert could not decode audio.wav: exit status -15")  # …took afconvert too

    proc = InboxProcessor(cfg, background=False, decoder=killed_with_the_pass)
    assert proc.try_acquire()
    workers: list[InlineWorker] = []
    try:
        proc.run_pending(worker_factory(workers), should_stop=lambda: stopping[0])
    finally:
        proc.release()

    item = _item(store)
    assert item.state == "queued", item.status
    assert item.attempts == 0
    assert item.status["error"] is None
    assert workers == []


def test_a_decode_failure_without_a_stop_still_fails(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    install_fake_asr(monkeypatch, FakeEngine())
    cfg = make_cfg(tmp_path)
    store = InboxStore(cfg.inbox_root)
    _add(store, _three_part_clip(tmp_path))

    def broken(*_: Any, **__: Any) -> float:
        raise RuntimeError("afconvert could not decode audio.wav: exit status 1")

    proc = InboxProcessor(cfg, background=False, decoder=broken)
    assert proc.try_acquire()
    try:
        proc.run_pending(worker_factory([]), should_stop=lambda: False)
    finally:
        proc.release()

    item = _item(store)
    assert item.state == "failed" and item.attempts == 1
    assert item.status["error"].startswith("could not decode: ")
