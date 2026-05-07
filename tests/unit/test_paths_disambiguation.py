"""Tests for filename disambiguation across rapid restarts (US2)."""

from __future__ import annotations

from datetime import datetime, timezone
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


def _chunk(session_id: str, seq: int, start: datetime) -> AudioChunk:
    return AudioChunk(
        chunk_seq=seq,
        session_id=session_id,
        start_time=start,
        expected_duration_seconds=900.0,
        audio_path=Path("/tmp/x.wav"),
    )


def test_two_sessions_same_second_have_distinct_filenames(cfg: RuntimeConfig) -> None:
    start = datetime(2026, 5, 7, 9, 15, 0, tzinfo=timezone.utc)
    a = _chunk("20260507T091500_aaaa1111", 1, start)
    b = _chunk("20260507T091500_bbbb2222", 1, start)
    fa = paths.transcript_filename(a).name
    fb = paths.transcript_filename(b).name
    assert fa != fb
    assert "aaaa1111" in fa
    assert "bbbb2222" in fb


def test_disambiguate_handles_real_collision(tmp_path: Path) -> None:
    target = tmp_path / "091500_aaaa1111_001.md"
    target.write_text("first")
    new = paths.disambiguate_if_collides(target)
    assert new != target
    assert new.suffix == ".md"
    assert new.name.startswith("091500_aaaa1111_001_")


def test_chunk_seq_disambiguates_within_session(cfg: RuntimeConfig) -> None:
    start = datetime(2026, 5, 7, 9, 15, 0, tzinfo=timezone.utc)
    a = _chunk("20260507T091500_aaaa1111", 1, start)
    b = _chunk("20260507T091500_aaaa1111", 2, start)
    assert paths.transcript_filename(a) != paths.transcript_filename(b)
