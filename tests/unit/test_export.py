"""``huske export``: one file per day, incremental, safe to sync.

Covers the properties that make it usable by a folder-reading tool: exactly one
document per day, chronological, statements first, atomic writes, and a re-run
that does nothing when nothing changed.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.export import (
    EXPORT_FORMAT_VERSION,
    existing_digest,
    export_days,
    group_by_day,
    render_day,
)

TRANSCRIPT_A = """---
session_id: 20260727T093000_ab12
chunk_seq: 1
start_time: 2026-07-27T09:30:00+02:00
end_time: 2026-07-27T09:35:00+02:00
language: pt
---

# 2026-07-27 09:30

[09:30:05 · mic] we agreed to ship on friday

[09:31:10 · system] and the pricing model stays flat
"""

TRANSCRIPT_B = """---
session_id: 20260727T140000_cd34
chunk_seq: 1
start_time: 2026-07-27T14:00:00+02:00
end_time: 2026-07-27T14:04:00+02:00
language: pt
---

# 2026-07-27 14:00

[14:00:30 · mic] second session, different topic
"""

TRANSCRIPT_NEXT_DAY = """---
session_id: 20260728T101500_ef56
chunk_seq: 1
start_time: 2026-07-28T10:15:00+02:00
end_time: 2026-07-28T10:20:00+02:00
language: pt
---

# 2026-07-28 10:15

[10:15:00 · mic] standup ran long
"""


@pytest.fixture
def corpus(tmp_path: Path) -> Path:
    root = tmp_path / "transcripts"
    (root / "2026-07-27").mkdir(parents=True)
    (root / "2026-07-28").mkdir(parents=True)
    (root / "2026-07-27" / "093000_ab12_001.md").write_text(TRANSCRIPT_A, encoding="utf-8")
    (root / "2026-07-27" / "140000_cd34_001.md").write_text(TRANSCRIPT_B, encoding="utf-8")
    (root / "2026-07-28" / "101500_ef56_001.md").write_text(TRANSCRIPT_NEXT_DAY, encoding="utf-8")
    (root / "README.md").write_text("# generated\n", encoding="utf-8")
    return root


def _add_sidecar(transcript: Path, texts: list[str]) -> None:
    from huske.paths import statements_sidecar_path

    doc = json.loads(
        json.dumps(
            {
                "version": 1,
                "transcript_path": str(transcript.resolve()),
                "session_id": "20260727T093000_ab12",
                "source_sha256": "deadbeef",
                "model": "test",
                "backend": "test",
                "distilled_at": "2026-07-27T09:40:00+02:00",
                "statements": [
                    {
                        "text": t,
                        "start": "2026-07-27T09:30:05+02:00",
                        "end": "2026-07-27T09:31:00+02:00",
                        "sources": ["mic"],
                    }
                    for t in texts
                ],
            }
        )
    )
    statements_sidecar_path(transcript).write_text(json.dumps(doc), encoding="utf-8")


# --- grouping ---------------------------------------------------------------


def test_group_by_day_skips_generated_readme(corpus: Path) -> None:
    days = group_by_day(corpus)
    assert list(days) == ["2026-07-27", "2026-07-28"]
    assert len(days["2026-07-27"]) == 2


def test_group_by_day_on_missing_root(tmp_path: Path) -> None:
    assert group_by_day(tmp_path / "absent") == {}


# --- rendering --------------------------------------------------------------


def test_render_collapses_a_day_into_one_document(corpus: Path) -> None:
    day = "2026-07-27"
    rendered = render_day(day, sorted((corpus / day).glob("*.md")))
    assert rendered.path.name == "2026-07-27.md"
    assert rendered.transcripts == 2
    assert rendered.markdown.startswith("---\n")
    assert f"date: {day}" in rendered.markdown
    assert "sessions: 2" in rendered.markdown
    assert f"generator: huske export (format v{EXPORT_FORMAT_VERSION})" in rendered.markdown


def test_render_includes_both_sessions_in_time_order(corpus: Path) -> None:
    md = render_day("2026-07-27", sorted((corpus / "2026-07-27").glob("*.md"))).markdown
    assert md.index("09:30") < md.index("14:00")
    assert "session `20260727T093000_ab12`" in md
    assert "session `20260727T140000_cd34`" in md


def test_render_labels_sources_as_speakers(corpus: Path) -> None:
    md = render_day("2026-07-27", sorted((corpus / "2026-07-27").glob("*.md"))).markdown
    assert "**09:30 me:** we agreed to ship on friday" in md
    assert "**09:31 other:** and the pricing model stays flat" in md


def test_render_puts_statements_first(corpus: Path) -> None:
    transcript = corpus / "2026-07-27" / "093000_ab12_001.md"
    _add_sidecar(transcript, ["The release ships Friday.", "Pricing stays flat."])
    rendered = render_day("2026-07-27", sorted((corpus / "2026-07-27").glob("*.md")))
    assert rendered.statements == 2
    assert "## Key points" in rendered.markdown
    assert rendered.markdown.index("## Key points") < rendered.markdown.index("## Conversations")
    assert "The release ships Friday." in rendered.markdown


def test_statements_only_omits_the_verbatim_text(corpus: Path) -> None:
    transcript = corpus / "2026-07-27" / "093000_ab12_001.md"
    _add_sidecar(transcript, ["The release ships Friday."])
    md = render_day(
        "2026-07-27", sorted((corpus / "2026-07-27").glob("*.md")), statements_only=True
    ).markdown
    assert "## Key points" in md
    assert "## Conversations" not in md
    assert "we agreed to ship on friday" not in md


def test_render_survives_an_unparseable_file(corpus: Path) -> None:
    """A half-written or foreign .md must not sink the whole day."""
    (corpus / "2026-07-27" / "broken.md").write_text("no frontmatter here", encoding="utf-8")
    rendered = render_day("2026-07-27", sorted((corpus / "2026-07-27").glob("*.md")))
    assert rendered.transcripts == 2
    assert "we agreed to ship on friday" in rendered.markdown


def test_render_empty_day() -> None:
    rendered = render_day("2026-07-29", [])
    assert "No transcripts for this day" in rendered.markdown
    assert rendered.transcripts == 0


# --- incremental export -----------------------------------------------------


def test_export_writes_one_file_per_day(corpus: Path, tmp_path: Path) -> None:
    out = tmp_path / "export"
    result = export_days(corpus, out)
    assert sorted(result.written) == ["2026-07-27", "2026-07-28"]
    assert sorted(p.name for p in out.glob("*.md")) == ["2026-07-27.md", "2026-07-28.md"]


def test_second_export_is_a_noop(corpus: Path, tmp_path: Path) -> None:
    out = tmp_path / "export"
    export_days(corpus, out)
    again = export_days(corpus, out)
    assert again.written == []
    assert sorted(again.skipped) == ["2026-07-27", "2026-07-28"]


def test_changed_transcript_triggers_a_rewrite(corpus: Path, tmp_path: Path) -> None:
    out = tmp_path / "export"
    export_days(corpus, out)
    target = corpus / "2026-07-28" / "101500_ef56_001.md"
    target.write_text(TRANSCRIPT_NEXT_DAY.replace("ran long", "ran short"), encoding="utf-8")
    again = export_days(corpus, out)
    assert again.written == ["2026-07-28"]
    assert "ran short" in (out / "2026-07-28.md").read_text(encoding="utf-8")


def test_new_sidecar_triggers_a_rewrite(corpus: Path, tmp_path: Path) -> None:
    """Turning distillation on changes the export without touching a transcript."""
    out = tmp_path / "export"
    export_days(corpus, out)
    _add_sidecar(corpus / "2026-07-27" / "093000_ab12_001.md", ["Ships Friday."])
    again = export_days(corpus, out)
    assert again.written == ["2026-07-27"]
    assert "Ships Friday." in (out / "2026-07-27.md").read_text(encoding="utf-8")


def test_force_rewrites_unchanged_days(corpus: Path, tmp_path: Path) -> None:
    out = tmp_path / "export"
    export_days(corpus, out)
    again = export_days(corpus, out, force=True)
    assert sorted(again.written) == ["2026-07-27", "2026-07-28"]


def test_since_filters_older_days(corpus: Path, tmp_path: Path) -> None:
    out = tmp_path / "export"
    result = export_days(corpus, out, since="2026-07-28")
    assert result.written == ["2026-07-28"]
    assert not (out / "2026-07-27.md").exists()


def test_export_leaves_no_temp_files_behind(corpus: Path, tmp_path: Path) -> None:
    """A synced folder must never see a partial file."""
    out = tmp_path / "export"
    export_days(corpus, out)
    assert [p.name for p in out.iterdir() if p.name.startswith(".")] == []


def test_digest_stamp_roundtrips(corpus: Path, tmp_path: Path) -> None:
    out = tmp_path / "export"
    export_days(corpus, out)
    assert existing_digest(out / "2026-07-27.md")
    assert existing_digest(out / "absent.md") is None


# --- the command ------------------------------------------------------------


def test_cli_export(corpus: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    out = tmp_path / "export"
    result = CliRunner().invoke(
        app,
        [
            "export",
            "--config",
            "/nonexistent.toml",
            "--output-root",
            str(corpus),
            "--export-root",
            str(out),
        ],
    )
    assert result.exit_code == 0, result.stdout
    assert "2 day(s) written" in result.stdout
    assert (out / "2026-07-27.md").exists()


def test_cli_export_without_transcripts(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    result = CliRunner().invoke(
        app,
        [
            "export",
            "--config",
            "/nonexistent.toml",
            "--output-root",
            str(tmp_path / "absent"),
        ],
    )
    assert result.exit_code == 1
    assert "no transcripts" in result.stdout
