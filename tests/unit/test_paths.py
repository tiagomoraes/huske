"""Tests for huske.paths."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

import pytest

from huske import paths
from huske.config import RuntimeConfig
from huske.models import AudioChunk


@pytest.fixture
def cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
    )


def test_session_id_sortable_and_unique() -> None:
    when = datetime(2026, 5, 7, 9, 15, 0).astimezone()
    s1 = paths.generate_session_id(when)
    s2 = paths.generate_session_id(when)
    assert s1.startswith("20260507T091500_")
    assert s2.startswith("20260507T091500_")
    assert s1 != s2  # random suffix


def test_session_id_short_is_8_chars() -> None:
    sid = "20260507T091500_8a3f2c19"
    assert paths.session_id_short(sid) == "8a3f2c19"


def test_session_id_short_pads_short_suffix() -> None:
    sid = "20260507T091500_a"
    short = paths.session_id_short(sid)
    assert len(short) == 8
    assert short.startswith("a")


def test_day_folder_uses_local_date(cfg: RuntimeConfig) -> None:
    when = datetime(2026, 5, 7, 23, 55, 0).astimezone()
    folder = paths.day_folder(cfg, when)
    assert folder == cfg.output_root / "2026-05-07"


def test_transcript_filename_format() -> None:
    chunk = AudioChunk(
        chunk_seq=2,
        session_id="20260507T091500_8a3f2c19",
        start_time=datetime(2026, 5, 7, 9, 30, 0).astimezone(),
        expected_duration_seconds=900.0,
        audio_path=Path("/tmp/dummy.wav"),
    )
    fn = paths.transcript_filename(chunk)
    assert fn.name == "093000_8a3f2c19_002.md"


def test_transcript_path_under_correct_day_folder(cfg: RuntimeConfig) -> None:
    chunk = AudioChunk(
        chunk_seq=1,
        session_id="20260507T091500_8a3f2c19",
        start_time=datetime(2026, 5, 7, 23, 55, 0).astimezone(),
        expected_duration_seconds=900.0,
        audio_path=Path("/tmp/dummy.wav"),
    )
    p = paths.transcript_path(cfg, chunk)
    assert p == cfg.output_root / "2026-05-07" / "235500_8a3f2c19_001.md"


def test_disambiguate_if_collides_returns_unused_name(tmp_path: Path) -> None:
    target = tmp_path / "x.md"
    target.write_text("a")
    new = paths.disambiguate_if_collides(target)
    assert new != target
    assert new.parent == target.parent
    assert new.stem.startswith("x_")
    assert new.suffix == ".md"


def test_disambiguate_returns_target_if_free(tmp_path: Path) -> None:
    target = tmp_path / "free.md"
    assert paths.disambiguate_if_collides(target) == target


def test_audio_chunk_path(cfg: RuntimeConfig) -> None:
    p = paths.audio_chunk_path(
        cfg,
        "20260507T091500_8a3f",
        chunk_seq=3,
        start_time=datetime(2026, 5, 7, 9, 45, 0).astimezone(),
    )
    assert p.name == "0003_094500.wav"
    assert p.parent.name == "20260507T091500_8a3f"


def test_lock_path_inside_audio_root(cfg: RuntimeConfig) -> None:
    sid = "test"
    lp = paths.lock_path(paths.audio_root(cfg, sid))
    assert lp.name == ".lock"
    assert lp.parent == cfg.audio_root / sid


def test_asr_raw_path_is_txt_not_markdown() -> None:
    transcript = Path("/tmp/2026-05-07/093000_8a3f2c19_001.md")
    raw = paths.asr_raw_path(transcript)
    assert raw.name == "093000_8a3f2c19_001.asr.txt"
    assert raw.suffix == ".txt"


def test_filenames_sort_chronologically() -> None:
    times = [
        datetime(2026, 5, 7, 9, 15, 0),
        datetime(2026, 5, 7, 9, 30, 0),
        datetime(2026, 5, 7, 23, 45, 0),
    ]
    names = []
    for i, t in enumerate(times, start=1):
        chunk = AudioChunk(
            chunk_seq=i,
            session_id="20260507T091500_aaaa1111",
            start_time=t.astimezone(),
            expected_duration_seconds=900.0,
            audio_path=Path("/tmp/x.wav"),
        )
        names.append(paths.transcript_filename(chunk).name)
    assert names == sorted(names)
