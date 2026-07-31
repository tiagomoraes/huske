from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from huske_mcp.transcripts import (
    iter_transcript_paths,
    parse_transcript,
    window_transcript,
)


def write_transcript(root: Path) -> Path:
    start = datetime.fromisoformat("2026-07-30T09:00:00-03:00")
    end = start + timedelta(minutes=10)
    path = root / "2026-07-30" / "090000_abcd1234_001.md"
    path.parent.mkdir(parents=True)
    path.write_text(
        f"""---
session_id: 20260730T090000_abcd1234
chunk_seq: 1
date: 2026-07-30
start_time: {start.isoformat()}
end_time: {end.isoformat()}
language: pt
---

# 09:00 - 09:10

[09:00:00 · system] Vamos revisar o orçamento do trimestre.

[09:01:00 · mic] Aprovado, com limite de vinte mil reais.
""",
        encoding="utf-8",
    )
    return path


def test_parse_and_window(tmp_path: Path) -> None:
    root = tmp_path / "transcripts"
    path = write_transcript(root)
    transcript = parse_transcript(path, root)
    assert transcript.session_id.endswith("abcd1234")
    assert [run.source for run in transcript.runs] == ["system", "mic"]
    passages = window_transcript(transcript)
    assert len(passages) == 1
    assert "orçamento" in passages[0].text
    assert passages[0].sources == "system,mic"


def test_scanner_does_not_follow_symlinked_day(tmp_path: Path) -> None:
    root = tmp_path / "transcripts"
    outside = tmp_path / "outside"
    outside.mkdir()
    write_transcript(outside)
    root.mkdir()
    (root / "2026-07-30").symlink_to(
        outside / "2026-07-30", target_is_directory=True
    )
    assert iter_transcript_paths(root) == []
