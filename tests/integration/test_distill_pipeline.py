"""End-to-end distillation: transcript → distill → embed → two-stage search.

No LLM daemon (heuristic distiller) and no Metal (hashing embedder), so it runs
in CI — the same "exercise the whole pipeline without the heavy backend" pattern
as test_pipeline_no_whisper.py.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.config import RuntimeConfig
from huske.distill.runner import run_distill
from huske.mcp.tools import fetch_transcript, search_transcripts
from huske.paths import index_db_path, statements_db_path
from huske.search.embedder import HashingEmbedder
from huske.search.runner import run_index
from huske.search.store import PassageStore
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)

pytestmark = pytest.mark.integration


def _write_transcript(output_root: Path) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {
            "start": 0.0,
            "end": 5.0,
            "text": "We approved the marketing budget for the third quarter. The roadmap ships on Friday.",
            "source": "system",
        },
        {"start": 6.0, "end": 8.0, "text": "I will send the updated deck tonight.", "source": "microphone"},
    ]
    body = body_from_source_segments(start, segs)
    t = build_transcript_from_segments(
        session_id="20260507T093000_abcd1234",
        chunk_seq=1,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="en",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day = output_root / "2026-05-07"
    day.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day / "093000_abcd1234_001.md")


def test_distill_then_index_then_two_stage_search(tmp_path: Path) -> None:
    output_root = tmp_path / "transcripts"
    index_root = tmp_path / "index"
    _write_transcript(output_root)

    overrides = {
        "output_root": output_root,
        "index_root": index_root,
        "embedding_model": "hashing",
        "distill_model": "heuristic",
        "distill_enabled": True,
    }

    # 1) Distill → sidecars. 2) Index → embed passages AND statements.
    assert run_distill(cli_overrides=overrides, low_impact=False) == 0
    assert run_index(cli_overrides=overrides, low_impact=False) == 0

    cfg = RuntimeConfig(**overrides)
    emb = HashingEmbedder()
    pstore = PassageStore.open(index_db_path(cfg), embedding_model="hashing", dim=emb.dim, create=False)
    sstore = PassageStore.open(
        statements_db_path(cfg), embedding_model="hashing", dim=emb.dim, create=False
    )
    try:
        assert int(sstore.stats()["passages"]) >= 1  # statements were embedded
        assert int(pstore.stats()["passages"]) >= 1  # passages too

        # auto → statements; a "budget" query surfaces the distilled claim.
        out = search_transcripts(pstore, sstore, emb, "marketing budget approved", granularity="auto")
        assert out["results"], "expected a statement hit"
        sid = out["results"][0]["id"]
        assert "#s" in sid  # a statement id, not a passage id

        # fetch grounds the claim in the verbatim transcript.
        fetched = fetch_transcript(pstore, sstore, sid)
        assert fetched["metadata"]["kind"] == "statement"
        assert "source transcript" in fetched["text"]
        assert "marketing budget" in fetched["text"]
    finally:
        pstore.close()
        sstore.close()


def test_index_rebuild_reembeds_statements(tmp_path: Path) -> None:
    output_root = tmp_path / "transcripts"
    index_root = tmp_path / "index"
    _write_transcript(output_root)
    overrides = {
        "output_root": output_root,
        "index_root": index_root,
        "embedding_model": "hashing",
        "distill_model": "heuristic",
    }

    assert run_distill(cli_overrides=overrides, low_impact=False) == 0
    assert run_index(cli_overrides=overrides, low_impact=False) == 0

    # --rebuild drops both stores; the statement store must come back from the
    # sidecars (regression guard for the model-change rebuild path).
    assert run_index(cli_overrides=overrides, rebuild=True, low_impact=False) == 0

    cfg = RuntimeConfig(**overrides)
    emb = HashingEmbedder()
    sstore = PassageStore.open(
        statements_db_path(cfg), embedding_model="hashing", dim=emb.dim, create=False
    )
    try:
        assert int(sstore.stats()["passages"]) >= 1
    finally:
        sstore.close()
