"""Tests for huske.transcribe.writer."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest
import yaml

from huske import __version__
from huske.models import Transcript
from huske.transcribe.writer import (
    build_transcript_from_segments,
    render_transcript,
    write_transcript,
)


def _t(**overrides: object) -> Transcript:
    base: dict = dict(
        session_id="20260507T091500_8a3f2c19",
        chunk_seq=2,
        start_time=datetime(2026, 5, 7, 9, 30, 0, tzinfo=timezone.utc),
        end_time=datetime(2026, 5, 7, 9, 45, 0, tzinfo=timezone.utc),
        duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        body="Hello world.\n\nSecond paragraph.",
        huske_version=__version__,
    )
    base.update(overrides)
    return Transcript(**base)


def test_full_frontmatter_keys() -> None:
    rendered = render_transcript(_t())
    assert rendered.startswith("---\n")
    fm_block = rendered.split("---\n")[1]
    fm = yaml.safe_load(fm_block)
    expected_keys = {
        "session_id",
        "chunk_seq",
        "date",
        "start_time",
        "end_time",
        "duration_seconds",
        "duration_actual_seconds",
        "gap_seconds",
        "audio_sources",
        "model",
        "language",
        "incomplete",
        "huske_version",
    }
    assert expected_keys <= set(fm.keys())
    assert fm["chunk_seq"] == 2
    assert fm["audio_sources"] == ["microphone", "system"]


def test_silent_chunk_body() -> None:
    rendered = render_transcript(_t(body=""))
    assert "_(no speech detected)_" in rendered


def test_h1_heading_format() -> None:
    rendered = render_transcript(_t())
    assert "# 09:30 – 09:45" in rendered


def test_atomic_write_creates_parents(tmp_path: Path) -> None:
    target = tmp_path / "deep" / "nested" / "x.md"
    written = write_transcript(_t(), target)
    assert written == target
    assert written.exists()
    body = written.read_text(encoding="utf-8")
    assert body.startswith("---\n")
    assert body.endswith("\n")


def test_no_overwrite_on_collision(tmp_path: Path) -> None:
    target = tmp_path / "x.md"
    target.write_text("preexisting", encoding="utf-8")
    written = write_transcript(_t(), target)
    assert written != target
    assert written.exists()
    assert target.read_text() == "preexisting"


def test_build_helper_round_trip() -> None:
    t = build_transcript_from_segments(
        session_id="20260507T091500_8a3f2c19",
        chunk_seq=1,
        start_time=datetime(2026, 5, 7, 9, 0, 0, tzinfo=timezone.utc),
        end_time=datetime(2026, 5, 7, 9, 15, 0, tzinfo=timezone.utc),
        expected_duration_seconds=900.0,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        text="oi tudo bem",
    )
    rendered = render_transcript(t)
    assert "oi tudo bem" in rendered
    assert "audio_sources:\n- microphone" in rendered or "audio_sources: [microphone]" in rendered or "audio_sources:\n  - microphone" in rendered
