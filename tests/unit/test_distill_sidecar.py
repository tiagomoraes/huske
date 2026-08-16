"""Sidecar read/write: roundtrip, incremental hash check, corrupt tolerance."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from huske.distill.models import Statement, StatementSidecar
from huske.distill.sidecar import read_sidecar, sidecar_is_current, write_sidecar
from huske.paths import statements_sidecar_path

_START = datetime(2026, 5, 7, 9, 30, 0).astimezone()


def _sidecar(transcript: Path) -> StatementSidecar:
    return StatementSidecar(
        transcript_path=str(transcript),
        session_id="20260507T093000_abcd",
        source_sha256="deadbeef",
        model="heuristic",
        backend="fake",
        distilled_at="2026-05-07T09:45:00",
        statements=[
            Statement("budget approved", _START, _START + timedelta(seconds=5), ["system"]),
            Statement("deck to be sent", _START + timedelta(seconds=6), _START + timedelta(seconds=9), ["mic"]),
        ],
    )


def test_roundtrip_preserves_statements_and_times(tmp_path: Path) -> None:
    transcript = tmp_path / "2026-05-07" / "093000_abcd_001.md"
    transcript.parent.mkdir(parents=True)

    written = write_sidecar(transcript, _sidecar(transcript))
    assert written == statements_sidecar_path(transcript)
    assert written.name == "093000_abcd_001.statements.json"

    back = read_sidecar(transcript)
    assert back is not None
    assert back.session_id == "20260507T093000_abcd"
    assert [s.text for s in back.statements] == ["budget approved", "deck to be sent"]
    assert back.statements[0].start == _START  # tz-aware datetime preserved
    assert back.statements[0].sources == ["system"]


def test_is_current_matches_source_hash(tmp_path: Path) -> None:
    transcript = tmp_path / "2026-05-07" / "t.md"
    transcript.parent.mkdir(parents=True)
    write_sidecar(transcript, _sidecar(transcript))
    assert sidecar_is_current(transcript, "deadbeef")
    assert not sidecar_is_current(transcript, "other-hash")


def test_v1_statement_sidecar_is_not_current(tmp_path: Path) -> None:
    transcript = tmp_path / "2026-05-07" / "t.md"
    transcript.parent.mkdir(parents=True)
    old = _sidecar(transcript)
    old.version = 1
    write_sidecar(transcript, old)
    assert not sidecar_is_current(transcript, "deadbeef")


def test_missing_sidecar_reads_none(tmp_path: Path) -> None:
    assert read_sidecar(tmp_path / "nope.md") is None
    assert not sidecar_is_current(tmp_path / "nope.md", "x")


def test_corrupt_sidecar_reads_none(tmp_path: Path) -> None:
    transcript = tmp_path / "2026-05-07" / "t.md"
    transcript.parent.mkdir(parents=True)
    statements_sidecar_path(transcript).write_text("{not valid json", encoding="utf-8")
    assert read_sidecar(transcript) is None
