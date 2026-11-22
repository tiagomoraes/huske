"""Tests for huske.output_readme."""

from __future__ import annotations

from pathlib import Path

from huske.output_readme import MANAGED_MARKER, ensure_output_readme, write_managed


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


def test_agents_md_written_beside_the_readme(tmp_path: Path) -> None:
    ensure_output_readme(tmp_path)
    agents = (tmp_path / "AGENTS.md").read_text()
    assert agents.startswith(MANAGED_MARKER)
    assert "`YYYY-MM-DD/`" in agents
    assert "transcripts/" not in agents  # local layout has no prefix


def test_users_own_agents_md_is_left_alone(tmp_path: Path) -> None:
    (tmp_path / "AGENTS.md").write_text("mine", encoding="utf-8")
    ensure_output_readme(tmp_path)
    assert (tmp_path / "AGENTS.md").read_text() == "mine"


def test_write_managed_refreshes_only_marked_files(tmp_path: Path) -> None:
    target = tmp_path / "doc.md"
    assert write_managed(target, f"{MANAGED_MARKER}\nv1\n")
    assert not write_managed(target, f"{MANAGED_MARKER}\nv1\n")  # already current
    assert write_managed(target, f"{MANAGED_MARKER}\nv2\n")
    target.write_text("hand written", encoding="utf-8")
    assert not write_managed(target, f"{MANAGED_MARKER}\nv3\n")
    assert target.read_text() == "hand written"
