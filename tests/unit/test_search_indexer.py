"""End-to-end: write a transcript, index it, search it back."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.search.embedder import HashingEmbedder
from huske.search.indexer import Indexer, iter_transcripts
from huske.search.store import PassageStore
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _make_transcript(day_dir: Path, *, chunk_seq: int, phrase: str) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone() + timedelta(minutes=15 * chunk_seq)
    segs = [
        {"start": 0.0, "end": 2.0, "text": phrase, "source": "system"},
        {"start": 3.0, "end": 4.0, "text": "entendido, obrigado.", "source": "microphone"},
    ]
    body = body_from_source_segments(start, segs)
    t = build_transcript_from_segments(
        session_id="20260507T093000_8a3f2c19",
        chunk_seq=chunk_seq,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day_dir.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day_dir / f"09{chunk_seq:02d}00_8a3f2c19_{chunk_seq:03d}.md")


@pytest.fixture
def emb() -> HashingEmbedder:
    return HashingEmbedder(dim=64)


def test_index_and_search(tmp_path: Path, emb: HashingEmbedder) -> None:
    out = tmp_path / "transcripts"
    day = out / "2026-05-07"
    _make_transcript(day, chunk_seq=1, phrase="vamos falar sobre o orçamento de marketing")
    _make_transcript(day, chunk_seq=2, phrase="a arquitetura do banco de dados precisa mudar")

    store = PassageStore.open(tmp_path / "index" / "passages.db", embedding_model="hashing", dim=emb.dim)
    indexer = Indexer(store, emb)
    summary = indexer.backfill(out)

    assert summary.files_seen == 2
    assert summary.files_indexed == 2
    assert summary.files_failed == 0
    assert summary.passages >= 2

    hits = store.search(emb.embed_query("banco de dados arquitetura"), k=3)
    assert hits, "expected at least one hit"
    assert "banco de dados" in hits[0].text
    store.close()


def test_incremental_skips_unchanged(tmp_path: Path, emb: HashingEmbedder) -> None:
    out = tmp_path / "transcripts"
    _make_transcript(out / "2026-05-07", chunk_seq=1, phrase="conteúdo estável")
    store = PassageStore.open(tmp_path / "index" / "passages.db", embedding_model="hashing", dim=emb.dim)
    indexer = Indexer(store, emb)

    first = indexer.backfill(out)
    assert first.files_indexed == 1
    second = indexer.backfill(out)
    assert second.files_indexed == 0
    assert second.files_skipped == 1
    store.close()


class _SpyEmbedder(HashingEmbedder):
    """Hashing embedder that counts ``release()`` calls."""

    def __init__(self) -> None:
        super().__init__(dim=64)
        self.releases = 0

    def release(self) -> None:
        self.releases += 1


def test_backfill_releases_buffers_between_files(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    day = out / "2026-05-07"
    _make_transcript(day, chunk_seq=1, phrase="primeiro arquivo de teste")
    _make_transcript(day, chunk_seq=2, phrase="segundo arquivo de teste")

    emb = _SpyEmbedder()
    store = PassageStore.open(tmp_path / "index" / "passages.db", embedding_model="hashing", dim=emb.dim)
    indexer = Indexer(store, emb)

    summary = indexer.backfill(out, release_between_files=True)
    assert summary.files_seen == 2
    assert emb.releases == 2  # released once per file, regardless of outcome
    store.close()


def test_backfill_does_not_release_by_default(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    _make_transcript(out / "2026-05-07", chunk_seq=1, phrase="arquivo único")

    emb = _SpyEmbedder()
    store = PassageStore.open(tmp_path / "index" / "passages.db", embedding_model="hashing", dim=emb.dim)
    Indexer(store, emb).backfill(out)  # release_between_files defaults False
    assert emb.releases == 0
    store.close()


def test_iter_transcripts_excludes_readme(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    (out / "2026-05-07").mkdir(parents=True)
    (out / "2026-05-07" / "091500_x_001.md").write_text("x", encoding="utf-8")
    (out / "README.md").write_text("readme", encoding="utf-8")
    found = iter_transcripts(out)
    assert [p.name for p in found] == ["091500_x_001.md"]
