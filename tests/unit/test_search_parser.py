"""Parser round-trips against the real transcript writer (the contract)."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from huske.search.parser import ParseError, parse_transcript
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _write_transcript(tmp_path: Path, segments: list[dict[str, object]]) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    end = start + timedelta(minutes=15)
    body = body_from_source_segments(start, segments)
    t = build_transcript_from_segments(
        session_id="20260507T093000_8a3f2c19",
        chunk_seq=2,
        start_time=start,
        end_time=end,
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        text=body,
        segments=segments,
    )
    return write_transcript(t, tmp_path / "093000_8a3f2c19_002.md")


def test_parses_frontmatter_and_runs(tmp_path: Path) -> None:
    segments = [
        {"start": 0.0, "end": 2.0, "text": "Olá, vamos começar a reunião.", "source": "system"},
        {"start": 1.0, "end": 2.0, "text": "Oi, tudo certo.", "source": "microphone"},
        {"start": 8.0, "end": 9.0, "text": "Hoje queria revisar o roadmap.", "source": "system"},
    ]
    path = _write_transcript(tmp_path, segments)

    doc = parse_transcript(path)
    assert doc.session_id == "20260507T093000_8a3f2c19"
    assert doc.chunk_seq == 2
    assert doc.language == "pt"
    assert len(doc.runs) == 3
    # Sources are normalized to mic/system labels.
    assert {r.source for r in doc.runs} == {"mic", "system"}
    # Run datetimes are tz-aware and ordered.
    assert all(r.start.tzinfo is not None for r in doc.runs)
    assert [r.start for r in doc.runs] == sorted(r.start for r in doc.runs)
    assert doc.runs[0].text.startswith("Olá")


def test_no_speech_transcript_has_no_runs(tmp_path: Path) -> None:
    path = _write_transcript(tmp_path, [])
    doc = parse_transcript(path)
    assert doc.runs == []


def test_missing_frontmatter_raises(tmp_path: Path) -> None:
    bad = tmp_path / "bad.md"
    bad.write_text("# just a heading\n\nsome text\n", encoding="utf-8")
    try:
        parse_transcript(bad)
    except ParseError:
        return
    raise AssertionError("expected ParseError")
