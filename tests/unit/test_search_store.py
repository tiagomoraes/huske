"""PassageStore over sqlite-vec: filtered KNN, fetch, delete, mismatch."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.search.embedder import HashingEmbedder
from huske.search.models import Passage
from huske.search.store import (
    ModelMismatchError,
    PassageStore,
    StoreUnavailable,
)

_BASE = datetime(2026, 5, 7, 9, 30, 0).astimezone()
_EMB = HashingEmbedder(dim=64)


def _passage(uid: str, text: str, *, day: int, sources: list[str], session: str = "s1") -> Passage:
    return Passage(
        uid=uid,
        text=text,
        start=_BASE,
        end=_BASE + timedelta(seconds=30),
        sources=sources,
        session_id=session,
        day=day,
        path=f"/t/{session}/{uid.split('#')[0]}",
        title=f"title {uid}",
    )


def _open(tmp_path: Path) -> PassageStore:
    return PassageStore.open(
        tmp_path / "passages.db", embedding_model="hashing", dim=_EMB.dim
    )


def _put(store: PassageStore, passages: list[Passage]) -> None:
    # All passages from one transcript share a path == the upsert key.
    path = passages[0].path
    embs = _EMB.embed_passages([p.text for p in passages])
    store.upsert(path, f"hash-of-{path}", passages, embs)


def test_upsert_search_returns_nearest(tmp_path: Path) -> None:
    store = _open(tmp_path)
    ps = [
        _passage("a#0", "discussão sobre o roadmap do produto", day=20260507, sources=["system"]),
        _passage("a#1", "almoço e café da tarde", day=20260507, sources=["mic"]),
    ]
    _put(store, ps)

    hits = store.search(_EMB.embed_query("roadmap do produto"), k=2)
    assert hits[0].uid == "a#0"
    assert hits[0].score > hits[1].score
    assert hits[0].url == "file:///t/s1/a"
    store.close()


def test_filters_by_day_source_session(tmp_path: Path) -> None:
    store = _open(tmp_path)
    _put(
        store,
        [
            _passage("a#0", "roadmap mic", day=20260507, sources=["mic"], session="s1"),
            _passage("a#1", "roadmap system", day=20260508, sources=["system"], session="s1"),
        ],
    )
    _put(
        store,
        [_passage("b#0", "roadmap outro", day=20260507, sources=["mic"], session="s2")],
    )

    q = _EMB.embed_query("roadmap")
    # Day range.
    day_hits = store.search(q, k=10, day_from=20260508, day_to=20260508)
    assert {h.uid for h in day_hits} == {"a#1"}
    # Source filter (mic only).
    mic_hits = store.search(q, k=10, source="mic")
    assert all("mic" in h.sources for h in mic_hits)
    assert {h.uid for h in mic_hits} == {"a#0", "b#0"}
    # Session partition.
    sess_hits = store.search(q, k=10, session_id="s2")
    assert {h.uid for h in sess_hits} == {"b#0"}
    store.close()


def test_reindex_replaces_passages(tmp_path: Path) -> None:
    store = _open(tmp_path)
    _put(store, [_passage("a#0", "versão antiga", day=20260507, sources=["mic"])])
    assert store.stats()["passages"] == 1
    # Re-index same path with different content.
    _put(store, [_passage("a#0", "versão nova", day=20260507, sources=["mic"])])
    assert store.stats()["passages"] == 1
    hit = store.get_by_uid("a#0")
    assert hit is not None and "nova" in hit.text
    store.close()


def test_is_indexed_tracks_hash(tmp_path: Path) -> None:
    store = _open(tmp_path)
    _put(store, [_passage("a#0", "texto", day=20260507, sources=["mic"])])
    assert store.is_indexed("/t/s1/a", "hash-of-/t/s1/a")
    assert not store.is_indexed("/t/s1/a", "different-hash")
    store.close()


def test_neighbors_returns_adjacent(tmp_path: Path) -> None:
    store = _open(tmp_path)
    _put(
        store,
        [_passage(f"a#{i}", f"passagem {i}", day=20260507, sources=["mic"]) for i in range(3)],
    )
    nbrs = store.neighbors("a#1", before=1, after=1)
    assert {h.uid for h in nbrs} == {"a#0", "a#2"}
    store.close()


def test_model_mismatch_refused(tmp_path: Path) -> None:
    store = _open(tmp_path)
    store.close()
    with pytest.raises(ModelMismatchError):
        PassageStore.open(tmp_path / "passages.db", embedding_model="other-model", dim=_EMB.dim)
    with pytest.raises(ModelMismatchError):
        PassageStore.open(tmp_path / "passages.db", embedding_model="hashing", dim=128)


def test_open_missing_index_without_create_raises(tmp_path: Path) -> None:
    with pytest.raises(StoreUnavailable):
        PassageStore.open(tmp_path / "nope.db", create=False)
