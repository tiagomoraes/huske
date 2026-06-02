"""search/fetch tool logic (no `mcp` import needed)."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.mcp.tools import (
    UnknownPassageError,
    _date_to_day,
    _normalize_source,
    fetch_passage,
    search_passages,
)
from huske.search.embedder import HashingEmbedder
from huske.search.models import Passage
from huske.search.store import PassageStore

_BASE = datetime(2026, 5, 7, 9, 30, 0).astimezone()
_EMB = HashingEmbedder(dim=64)


def _passage(idx: int, text: str, *, day: int = 20260507, sources: list[str] | None = None) -> Passage:
    return Passage(
        uid=f"/t/a#{idx}",
        text=text,
        start=_BASE + timedelta(seconds=idx),
        end=_BASE + timedelta(seconds=idx + 5),
        sources=sources or ["mic", "system"],
        session_id="s1",
        day=day,
        path="/t/a",
        title=f"title {idx}",
    )


@pytest.fixture
def store(tmp_path: Path) -> PassageStore:
    s = PassageStore.open(tmp_path / "p.db", embedding_model="hashing", dim=_EMB.dim)
    ps = [
        _passage(0, "planejamento do orçamento anual", sources=["system"]),
        _passage(1, "detalhes do orçamento e custos", sources=["mic"]),
        _passage(2, "discussão sobre contratações", day=20260601, sources=["mic", "system"]),
    ]
    s.upsert("/t/a", "h", ps, _EMB.embed_passages([p.text for p in ps]))
    return s


def test_search_returns_chatgpt_shape(store: PassageStore) -> None:
    out = search_passages(store, _EMB, "orçamento anual", k=3)
    assert "results" in out
    assert out["results"], "expected hits"
    first = out["results"][0]
    assert set(first) >= {"id", "title", "url"}  # ChatGPT contract
    assert "orçamento" in first["title"] or first["id"].startswith("/t/a#")


def test_search_filters_by_source_and_date(store: PassageStore) -> None:
    mic = search_passages(store, _EMB, "orçamento", source="mic", k=10)
    ids = {r["id"] for r in mic["results"]}
    assert "/t/a#1" in ids and "/t/a#0" not in ids  # #0 is system-only

    jun = search_passages(store, _EMB, "contratações", date_from="2026-06-01", k=10)
    assert {r["id"] for r in jun["results"]} == {"/t/a#2"}


def test_fetch_returns_metadata(store: PassageStore) -> None:
    out = fetch_passage(store, "/t/a#1")
    assert out["id"] == "/t/a#1"
    assert "orçamento" in out["text"]
    assert out["url"] == "file:///t/a"
    assert set(out["metadata"]) >= {"session", "day", "time_range", "sources", "path"}
    assert out["metadata"]["session"] == "s1"


def test_fetch_with_context_stitches_neighbors(store: PassageStore) -> None:
    out = fetch_passage(store, "/t/a#1", context=1)
    # Neighbors #0 and #2 stitched in numeric order around #1.
    assert "orçamento anual" in out["text"]  # #0
    assert "contratações" in out["text"]  # #2


def test_fetch_unknown_raises(store: PassageStore) -> None:
    with pytest.raises(UnknownPassageError):
        fetch_passage(store, "/t/a#999")


def test_helpers() -> None:
    assert _date_to_day("2026-05-07") == 20260507
    assert _date_to_day(None) is None
    assert _normalize_source("microphone") == "mic"
    assert _normalize_source("System") == "system"
    assert _normalize_source("garbage") is None
