"""Engine inbox store: ids, idempotent atomic staging, status, lock, pruning."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from huske.inbox import store as store_mod
from huske.inbox.store import (
    InboxError,
    InboxLock,
    InboxStore,
    iso,
    now_local,
    parse_timestamp,
    session_id_for,
    validate_id,
)

from ._inbox_fakes import tone, write_wav


@pytest.fixture
def store(tmp_path: Path) -> InboxStore:
    return InboxStore(tmp_path / "inbox")


@pytest.fixture
def clip(tmp_path: Path) -> Path:
    return write_wav(tmp_path / "src" / "Reunião.wav", tone(2.0))


def test_add_copies_into_an_item_with_both_documents(store: InboxStore, clip: Path) -> None:
    item, created = store.add(
        clip,
        item_id="4E1C0A5B-0F7E",
        title="Reunião com a Ana",
        device="iPhone de Tiago",
        origin="phone",
        started_at=parse_timestamp("2026-11-19T14:03:00-03:00"),
        duration_seconds=2.0,
    )

    assert created is True
    assert clip.exists()  # copied, not moved
    item_dir = store.root / "4E1C0A5B-0F7E"
    assert sorted(p.name for p in item_dir.iterdir()) == [
        "audio.wav",
        "recording.json",
        "status.json",
    ]
    recording = json.loads((item_dir / "recording.json").read_text())
    assert recording == {
        "id": "4E1C0A5B-0F7E",
        "title": "Reunião com a Ana",
        "origin": "phone",
        "device": "iPhone de Tiago",
        "started_at": "2026-11-19T14:03:00-03:00",
        "duration_seconds": 2.0,
        "audio_file": "audio.wav",
        "source_filename": "Reunião.wav",
        "added_at": recording["added_at"],
    }
    status = json.loads((item_dir / "status.json").read_text())
    assert status["state"] == "queued"
    assert status["attempts"] == 0
    assert status["transcripts"] == []
    assert status["error"] is None
    assert status["session_id"] == session_id_for(
        "4E1C0A5B-0F7E", parse_timestamp("2026-11-19T14:03:00-03:00")
    )
    assert item.to_dict()["title"] == "Reunião com a Ana"
    assert item.to_dict()["state"] == "queued"
    # Nothing left behind in staging.
    assert list((store.root / ".staging").iterdir()) == []


def test_re_adding_an_id_is_a_no_op_that_returns_the_existing_item(
    store: InboxStore, clip: Path, tmp_path: Path
) -> None:
    first, created = store.add(clip, item_id="rec-1", title="first")
    store.write_status(first, state="done", transcripts=["/x.md"])
    other = write_wav(tmp_path / "other.wav", tone(1.0, freq=440))

    again, created_again = store.add(other, item_id="rec-1", title="second", move=True)

    assert created and not created_again
    assert again.state == "done"
    assert again.recording["title"] == "first"
    assert other.exists()  # --move of a duplicate never consumes the file
    assert [p.name for p in store.root.iterdir() if not p.name.startswith(".")] == ["rec-1"]


def test_default_id_is_a_content_hash_so_reimporting_is_idempotent(
    store: InboxStore, clip: Path, tmp_path: Path
) -> None:
    copy = tmp_path / "copy.wav"
    copy.write_bytes(clip.read_bytes())

    a, created_a = store.add(clip)
    b, created_b = store.add(copy)

    assert a.id.startswith("file-") and len(a.id) == 5 + 24
    assert a.id == b.id
    assert created_a and not created_b


def test_move_takes_the_file(store: InboxStore, clip: Path) -> None:
    item, _ = store.add(clip, item_id="moved", move=True)
    assert not clip.exists()
    assert item.audio_path.read_bytes()[:4] == b"RIFF"


@pytest.mark.parametrize(
    "bad", ["", ".", "..", ".lock", ".staging", "a/b", "a b", "é", "x" * 65]
)
def test_invalid_ids_are_rejected(store: InboxStore, clip: Path, bad: str) -> None:
    with pytest.raises(InboxError):
        validate_id(bad)
    with pytest.raises(InboxError):
        store.add(clip, item_id=bad)


def test_valid_id_forms() -> None:
    for good in ["4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11", "a", "x" * 64, "v1.2_rec-3"]:
        assert validate_id(good) == good


def test_validation_errors(store: InboxStore, clip: Path, tmp_path: Path) -> None:
    with pytest.raises(InboxError, match="no such file"):
        store.add(tmp_path / "missing.m4a")
    with pytest.raises(InboxError, match="origin"):
        store.add(clip, origin="cloud")
    with pytest.raises(InboxError, match="duration"):
        store.add(clip, duration_seconds=-1.0)
    with pytest.raises(InboxError, match="ISO 8601"):
        parse_timestamp("yesterday")


def test_failed_staging_leaves_no_item_and_restores_a_moved_file(
    store: InboxStore, clip: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    real = store_mod._write_json_atomic

    def explode(path: Path, data: dict[str, object]) -> None:
        if path.name == "status.json":
            raise OSError("disk full")
        real(path, data)

    monkeypatch.setattr(store_mod, "_write_json_atomic", explode)
    with pytest.raises(OSError, match="disk full"):
        store.add(clip, item_id="half", move=True)

    assert clip.exists()  # the producer's file came back
    assert not (store.root / "half").exists()
    assert list((store.root / ".staging").iterdir()) == []
    assert store.get("half") is None


def test_incomplete_directories_are_invisible(store: InboxStore) -> None:
    (store.root / "no-recording").mkdir(parents=True)
    (store.root / ".staging" / "x.123").mkdir(parents=True)
    assert store.items() == []


def test_started_at_defaults_to_mtime_minus_duration(store: InboxStore, clip: Path) -> None:
    mtime = datetime(2026, 11, 19, 15, 0, 0).astimezone()
    os.utime(clip, (mtime.timestamp(), mtime.timestamp()))

    item, _ = store.add(clip, item_id="probe")

    assert item.recording["duration_seconds"] == pytest.approx(2.0)
    assert item.started_at == mtime - timedelta(seconds=2)


def test_naive_started_at_is_mac_local(store: InboxStore, clip: Path) -> None:
    item, _ = store.add(clip, item_id="naive", started_at=parse_timestamp("2026-11-19T09:00:00"))
    assert item.started_at.tzinfo is not None
    assert item.started_at == datetime(2026, 11, 19, 9, 0, 0).astimezone()


def test_session_id_is_deterministic_and_mac_local() -> None:
    started = parse_timestamp("2026-11-19T14:03:00-03:00")
    sid = session_id_for("4E1C0A5B", started)
    assert sid == session_id_for("4E1C0A5B", started)
    local = started.astimezone()
    import hashlib

    assert sid == f"{local.strftime('%Y%m%dT%H%M%S')}_{hashlib.sha1(b'4E1C0A5B').hexdigest()[:8]}"
    assert sid != session_id_for("other", started)


def test_list_is_newest_first(store: InboxStore, clip: Path) -> None:
    ids = ["a", "b", "c"]
    for i, item_id in enumerate(ids):
        item, _ = store.add(clip, item_id=item_id)
        item.recording["added_at"] = iso(now_local() + timedelta(minutes=i))
        (item.dir / "recording.json").write_text(json.dumps(item.recording))
    assert [i.id for i in store.list_newest_first()] == ["c", "b", "a"]


def test_status_write_is_atomic_and_stamped(store: InboxStore, clip: Path) -> None:
    item, _ = store.add(clip, item_id="s")
    store.write_status(item, state="processing", attempts=1)
    on_disk = json.loads((item.dir / "status.json").read_text())
    assert on_disk["state"] == "processing" and on_disk["attempts"] == 1
    assert parse_timestamp(on_disk["updated_at"]).tzinfo is not None
    assert not [p for p in item.dir.iterdir() if p.name.endswith(".tmp")]


def test_audio_path_cannot_escape_the_item(store: InboxStore, clip: Path) -> None:
    item, _ = store.add(clip, item_id="esc")
    item.recording["audio_file"] = "../../etc/passwd"
    assert item.audio_path.parent == item.dir


def test_prune_removes_old_done_items_and_stale_staging(store: InboxStore, clip: Path) -> None:
    now = now_local()
    for item_id, state, age_days in [
        ("old-done", "done", 31),
        ("new-done", "done", 29),
        ("old-queued", "queued", 90),
        ("old-failed", "failed", 90),
    ]:
        item, _ = store.add(clip, item_id=item_id)
        status = {**item.status, "state": state, "updated_at": iso(now - timedelta(days=age_days))}
        (item.dir / "status.json").write_text(json.dumps(status))
    stale = store.root / ".staging" / "crashed.abc"
    stale.mkdir(parents=True)
    old = (now - timedelta(days=2)).timestamp()
    os.utime(stale, (old, old))
    fresh = store.root / ".staging" / "copying.def"
    fresh.mkdir()

    assert store.prune(now) == ["old-done"]
    assert {i.id for i in store.items()} == {"new-done", "old-queued", "old-failed"}
    assert not stale.exists()
    assert fresh.exists()


def test_lock_is_exclusive_within_a_process(tmp_path: Path) -> None:
    a = InboxLock(tmp_path / "inbox")
    b = InboxLock(tmp_path / "inbox")
    assert a.try_acquire()
    assert a.try_acquire()  # re-entrant for its holder
    assert not b.try_acquire()
    assert b.locked_elsewhere()
    a.release()
    assert b.try_acquire()
    b.release()


def test_lock_is_exclusive_across_processes_and_dies_with_its_holder(tmp_path: Path) -> None:
    root = tmp_path / "inbox"
    holder = subprocess.Popen(
        [
            sys.executable,
            "-c",
            textwrap.dedent(
                f"""
                import sys, time
                from huske.inbox.store import InboxLock
                lock = InboxLock({str(root)!r})
                assert lock.try_acquire()
                print("held", flush=True)
                time.sleep(30)
                """
            ),
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        assert holder.stdout is not None
        assert holder.stdout.readline().strip() == "held"
        mine = InboxLock(root)
        assert not mine.try_acquire()
        holder.kill()
        holder.wait(timeout=5)
        # The kernel drops a dead holder's flock: no stale locks.
        assert mine.try_acquire()
        mine.release()
    finally:
        if holder.poll() is None:
            holder.kill()
            holder.wait(timeout=5)
