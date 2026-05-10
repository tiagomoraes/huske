"""Tests for huske.output_readme."""

from __future__ import annotations

from pathlib import Path

from huske.output_readme import ensure_output_readme


def test_creates_when_missing(tmp_path: Path) -> None:
    target = ensure_output_readme(tmp_path)
    assert target == tmp_path / "README.md"
    assert target.exists()
    assert "Huske transcripts" in target.read_text()


def test_idempotent_when_content_matches(tmp_path: Path) -> None:
    ensure_output_readme(tmp_path)
    target = tmp_path / "README.md"
    mtime1 = target.stat().st_mtime_ns
    ensure_output_readme(tmp_path)
    mtime2 = target.stat().st_mtime_ns
    assert mtime1 == mtime2  # no rewrite


def test_rewrites_when_drifted(tmp_path: Path) -> None:
    target = tmp_path / "README.md"
    target.write_text("stale content", encoding="utf-8")
    ensure_output_readme(tmp_path)
    assert "Huske transcripts" in target.read_text()
