from __future__ import annotations

from pathlib import Path

from test_transcripts import write_transcript

from huske_mcp.index import TranscriptIndex


def test_incremental_fts_fetch_recap_and_removal(tmp_path: Path) -> None:
    root = tmp_path / "transcripts"
    path = write_transcript(root)
    index = TranscriptIndex(tmp_path / "index.sqlite3")
    try:
        first = index.refresh(root)
        assert first.indexed == 1
        assert first.passages == 1

        second = index.refresh(root)
        assert second.indexed == 0

        result = index.search("orçamento trimestre", date_from="2026-07-30")
        assert result["mode"] == "fts5"
        assert len(result["results"]) == 1
        passage_id = int(result["results"][0]["id"])

        fetched = index.fetch(passage_id)
        assert "vinte mil" in fetched["text"]
        recap = index.recap(date_from="2026-07-30", date_to="2026-07-30")
        assert len(recap["items"]) == 1
        assert index.overview()["transcripts"] == 1

        path.write_text("not a transcript", encoding="utf-8")
        malformed = index.refresh(root)
        assert malformed.failed == 1
        assert index.overview()["transcripts"] == 0

        path.unlink()
        removed = index.refresh(root)
        assert removed.removed == 0
        assert index.overview()["transcripts"] == 0
    finally:
        index.close()
