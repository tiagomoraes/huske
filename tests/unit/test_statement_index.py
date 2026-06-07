"""StatementIndexer + two-stage MCP search/fetch (statements grounded in passages).

Uses HashingEmbedder + a real sqlite-vec store (skipped without the extra).
"""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.distill.models import Statement, StatementSidecar
from huske.distill.sidecar import write_sidecar
from huske.mcp.tools import fetch_transcript, search_transcripts
from huske.search.embedder import HashingEmbedder
from huske.search.indexer import StatementIndexer
from huske.search.models import Passage
from huske.search.store import PassageStore

_BASE = datetime(2026, 5, 7, 9, 30, 0).astimezone()
_EMB = HashingEmbedder(dim=64)


def _transcript_with_sidecar(tmp_path: Path, statements: list[Statement]) -> tuple[Path, str]:
    day = tmp_path / "transcripts" / "2026-05-07"
    day.mkdir(parents=True, exist_ok=True)
    tp = day / "093000_abcd_001.md"
    tp.write_text("---\nsession_id: s1\n---\n\nbody\n", encoding="utf-8")
    key = str(tp.resolve())
    write_sidecar(
        tp,
        StatementSidecar(
            transcript_path=key,
            session_id="s1",
            source_sha256="sha-1",
            model="heuristic",
            backend="fake",
            distilled_at="t",
            statements=statements,
        ),
    )
    return tp, key


def test_statement_indexer_embeds_and_searches(tmp_path: Path) -> None:
    stmts = [
        Statement("the budget was approved", _BASE + timedelta(seconds=5), _BASE + timedelta(seconds=8), ["system"]),
        Statement("the deck will be sent on friday", _BASE + timedelta(seconds=9), _BASE + timedelta(seconds=12), ["mic"]),
    ]
    tp, key = _transcript_with_sidecar(tmp_path, stmts)
    store = PassageStore.open(tmp_path / "statements.db", embedding_model="hashing", dim=_EMB.dim)
    idx = StatementIndexer(store, _EMB)

    assert idx.index_file(tp) == 2
    hit = store.get_by_uid(f"{key}#s0")
    assert hit is not None and "budget" in hit.title  # title is the claim itself
    found = store.search(_EMB.embed_query("budget approved"), k=2)
    assert found and "budget" in found[0].text
    assert idx.index_file(tp) == 0  # incremental: unchanged sidecar → skip
    store.close()


def test_two_stage_search_then_fetch_grounds_in_transcript(tmp_path: Path) -> None:
    stmts = [
        Statement("the budget was approved", _BASE + timedelta(seconds=5), _BASE + timedelta(seconds=8), ["system"])
    ]
    tp, key = _transcript_with_sidecar(tmp_path, stmts)
    sstore = PassageStore.open(tmp_path / "statements.db", embedding_model="hashing", dim=_EMB.dim)
    StatementIndexer(sstore, _EMB).index_file(tp)

    pstore = PassageStore.open(tmp_path / "passages.db", embedding_model="hashing", dim=_EMB.dim)
    passage = Passage(
        uid=f"{key}#0",
        text="we talked at length about the quarterly budget and finally approved it",
        start=_BASE,
        end=_BASE + timedelta(seconds=30),
        sources=["system"],
        session_id="s1",
        day=20260507,
        path=key,
        title="passage title",
    )
    pstore.upsert(key, "ph", [passage], _EMB.embed_passages([passage.text]))

    # auto → statements (the statement store has rows).
    out = search_transcripts(pstore, sstore, _EMB, "budget approved", granularity="auto")
    assert out["results"], "expected statement hits"
    sid = out["results"][0]["id"]
    assert sid == f"{key}#s0"

    # fetch the statement → claim + the verbatim source transcript that grounds it.
    fetched = fetch_transcript(pstore, sstore, sid)
    assert fetched["metadata"]["kind"] == "statement"
    assert "budget was approved" in fetched["text"]
    assert "source transcript" in fetched["text"]
    assert "quarterly budget" in fetched["text"]  # grounding passage stitched in by time range

    # granularity='passage' searches raw transcript and fetches a passage.
    pout = search_transcripts(pstore, sstore, _EMB, "quarterly budget", granularity="passage")
    assert pout["results"][0]["id"] == f"{key}#0"
    pf = fetch_transcript(pstore, sstore, f"{key}#0")
    assert pf["metadata"]["kind"] == "passage"

    sstore.close()
    pstore.close()


def test_auto_falls_back_to_passages_without_statement_store(tmp_path: Path) -> None:
    pstore = PassageStore.open(tmp_path / "passages.db", embedding_model="hashing", dim=_EMB.dim)
    key = "/t/a"
    p = Passage(
        uid=f"{key}#0", text="roadmap planning", start=_BASE, end=_BASE + timedelta(seconds=10),
        sources=["mic"], session_id="s1", day=20260507, path=key, title="t",
    )
    pstore.upsert(key, "h", [p], _EMB.embed_passages([p.text]))
    out = search_transcripts(pstore, None, _EMB, "roadmap", granularity="auto")
    assert out["results"][0]["id"] == f"{key}#0"
    pstore.close()


def test_statement_granularity_without_store_raises(tmp_path: Path) -> None:
    pstore = PassageStore.open(tmp_path / "passages.db", embedding_model="hashing", dim=_EMB.dim)
    with pytest.raises(ValueError):
        search_transcripts(pstore, None, _EMB, "x", granularity="statement")
    pstore.close()
