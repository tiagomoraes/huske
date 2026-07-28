"""``recap`` and ``overview``: time-scoped recall with no embedding involved."""

from __future__ import annotations

import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.mcp.tools import MAX_RECAP_ITEMS, overview, recap
from huske.search.embedder import HashingEmbedder
from huske.search.models import Passage
from huske.search.store import PassageStore

_EMB = HashingEmbedder(dim=32)
_DAY1 = datetime(2026, 7, 27, 9, 30, 0).astimezone()
_DAY2 = datetime(2026, 7, 28, 14, 5, 0).astimezone()


def _passage(uid: str, text: str, start: datetime, *, session: str, path: str, source: str) -> Passage:
    return Passage(
        uid=uid,
        text=text,
        start=start,
        end=start + timedelta(minutes=2),
        sources=[source],
        session_id=session,
        day=int(start.strftime("%Y%m%d")),
        path=path,
        title=f"{start.date().isoformat()} {start.strftime('%H:%M')} · {source}",
    )


def _write(store: PassageStore, path: str, passages: list[Passage]) -> None:
    store.upsert(path, f"hash-{path}", passages, _EMB.embed_passages([p.text for p in passages]))


@pytest.fixture
def store(tmp_path: Path) -> PassageStore:
    s = PassageStore.open(tmp_path / "p.db", embedding_model="hashing", dim=_EMB.dim)
    _write(
        s,
        "/t/day1",
        [
            _passage("/t/day1#0", "we agreed to ship on friday", _DAY1, session="s1", path="/t/day1", source="mic"),
            _passage(
                "/t/day1#1",
                "the pricing model stays flat",
                _DAY1 + timedelta(minutes=5),
                session="s1",
                path="/t/day1",
                source="system",
            ),
        ],
    )
    _write(
        s,
        "/t/day2",
        [_passage("/t/day2#0", "standup ran long", _DAY2, session="s2", path="/t/day2", source="mic")],
    )
    return s


@pytest.fixture
def statements(tmp_path: Path) -> PassageStore:
    s = PassageStore.open(tmp_path / "s.db", embedding_model="hashing", dim=_EMB.dim)
    _write(
        s,
        "/t/day2",
        [
            _passage(
                "/t/day2!0",
                "The team decided the release ships Friday.",
                _DAY2,
                session="s2",
                path="/t/day2",
                source="mic",
            )
        ],
    )
    return s


# --- recap ------------------------------------------------------------------


def test_recap_defaults_to_the_latest_recorded_day(store: PassageStore) -> None:
    """Not the calendar's today: the server may be in another timezone, and a
    quiet weekend would otherwise read as 'nothing was discussed'."""
    result = recap(store, None)
    assert result["range"]["from"] == "2026-07-28"
    assert result["range"]["to"] == "2026-07-28"
    assert result["range"]["resolved_as"]
    assert [d["date"] for d in result["days"]] == ["2026-07-28"]


def test_recap_over_a_range_groups_by_day_and_session(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-28")
    assert [d["date"] for d in result["days"]] == ["2026-07-27", "2026-07-28"]
    day1 = result["days"][0]
    assert [s["session_id"] for s in day1["sessions"]] == ["s1"]
    assert [i["id"] for i in day1["sessions"][0]["items"]] == ["/t/day1#0", "/t/day1#1"]
    assert result["item_count"] == 3


def test_recap_items_carry_time_and_source(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-27")
    items = result["days"][0]["sessions"][0]["items"]
    assert items[0]["time"] == "09:30"
    assert items[0]["sources"] == "mic"
    assert items[1]["sources"] == "system"


def test_recap_is_chronological(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-28")
    times = [
        item["time"]
        for day in result["days"]
        for session in day["sessions"]
        for item in session["items"]
    ]
    assert times == sorted(times)


def test_recap_filters_by_source(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-27", source="system")
    ids = [i["id"] for i in result["days"][0]["sessions"][0]["items"]]
    assert ids == ["/t/day1#1"]


def test_recap_filters_by_session(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-28", session="s2")
    assert [d["date"] for d in result["days"]] == ["2026-07-28"]


def test_recap_truncation_is_announced(store: PassageStore) -> None:
    """A silent cap would read as 'that was everything'."""
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-28", max_items=1)
    assert result["truncated"] is True
    assert result["item_count"] == 1
    assert "max_items" in result["note"]


def test_recap_not_truncated_when_it_fits(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-07-27", date_to="2026-07-28", max_items=50)
    assert result["truncated"] is False


def test_recap_max_items_is_clamped(store: PassageStore) -> None:
    result = recap(store, None, max_items=10_000)
    assert result["item_count"] <= MAX_RECAP_ITEMS


def test_recap_empty_range_is_explicit(store: PassageStore) -> None:
    result = recap(store, None, date_from="2026-01-01", date_to="2026-01-02")
    assert result["days"] == []
    assert result["item_count"] == 0


def test_recap_on_empty_index_says_so(tmp_path: Path) -> None:
    empty = PassageStore.open(tmp_path / "e.db", embedding_model="hashing", dim=_EMB.dim)
    result = recap(empty, None)
    assert result["item_count"] == 0
    assert "huske index" in result["note"]


def test_recap_accepts_a_one_sided_range(store: PassageStore) -> None:
    """'everything since the 28th' is a normal call; the open end stays open."""
    result = recap(store, None, date_from="2026-07-28")
    assert result["range"] == {"from": "2026-07-28", "to": None}
    assert [d["date"] for d in result["days"]] == ["2026-07-28"]

    result = recap(store, None, date_to="2026-07-27")
    assert result["range"] == {"from": None, "to": "2026-07-27"}
    assert [d["date"] for d in result["days"]] == ["2026-07-27"]


def test_recap_rejects_a_malformed_date(store: PassageStore) -> None:
    with pytest.raises(ValueError, match="YYYY-MM-DD"):
        recap(store, None, date_from="27/07/2026")


def test_recap_prefers_statements_when_available(
    store: PassageStore, statements: PassageStore
) -> None:
    result = recap(store, statements)
    assert result["kind"] == "statement"
    assert "verbatim transcript" in result["note"]
    ids = [i["id"] for d in result["days"] for s in d["sessions"] for i in s["items"]]
    assert ids == ["/t/day2!0"]


def test_recap_granularity_forces_passages(store: PassageStore, statements: PassageStore) -> None:
    result = recap(store, statements, granularity="passage")
    assert result["kind"] == "passage"
    ids = [i["id"] for d in result["days"] for s in d["sessions"] for i in s["items"]]
    assert ids == ["/t/day2#0"]


# --- overview ---------------------------------------------------------------


def test_overview_reports_coverage(store: PassageStore) -> None:
    result = overview(store, None)
    assert result["first_day"] == "2026-07-27"
    assert result["last_day"] == "2026-07-28"
    assert result["passages"] == 3
    assert result["transcripts"] == 2
    assert result["statements"] == 0


def test_overview_lists_recent_days_newest_first(store: PassageStore) -> None:
    days = overview(store, None)["recent_days"]
    assert [d["date"] for d in days] == ["2026-07-28", "2026-07-27"]
    assert [d["passages"] for d in days] == [1, 2]


def test_overview_counts_statements_per_day(
    store: PassageStore, statements: PassageStore
) -> None:
    days = overview(store, statements)["recent_days"]
    by_date = {d["date"]: d for d in days}
    assert by_date["2026-07-28"]["statements"] == 1
    assert by_date["2026-07-27"]["statements"] == 0
    assert overview(store, statements)["statements"] == 1


def test_overview_honors_recent_days_window(store: PassageStore) -> None:
    assert len(overview(store, None, recent_days=1)["recent_days"]) == 1


def test_overview_on_empty_index(tmp_path: Path) -> None:
    empty = PassageStore.open(tmp_path / "e.db", embedding_model="hashing", dim=_EMB.dim)
    result = overview(empty, None)
    assert result["first_day"] is None
    assert result["passages"] == 0
    assert result["recent_days"] == []


# --- the store reads behind them --------------------------------------------


def test_in_day_range_returns_rows_in_time_order(store: PassageStore) -> None:
    hits = store.in_day_range()
    assert [h.uid for h in hits] == ["/t/day1#0", "/t/day1#1", "/t/day2#0"]


def test_in_day_range_respects_limit(store: PassageStore) -> None:
    assert len(store.in_day_range(limit=2)) == 2


def test_day_counts_are_newest_first(store: PassageStore) -> None:
    assert store.day_counts() == [(20260728, 1), (20260727, 2)]


def test_day_bounds(store: PassageStore) -> None:
    assert store.day_bounds() == (20260727, 20260728)


def test_day_bounds_empty(tmp_path: Path) -> None:
    empty = PassageStore.open(tmp_path / "e.db", embedding_model="hashing", dim=_EMB.dim)
    assert empty.day_bounds() is None


# --- timezone: the clock must be the speaker's, not the reader's --------------
#
# The index stores epoch ms, so rendering with .astimezone() shows whoever is
# *reading*. That is invisible on the recording Mac and wrong on a VPS in another
# zone — a 09:30 meeting reported at 04:30. These lock the recorded offset in.


_TRANSCRIPT = """---
session_id: 20260727T093000_ab12
chunk_seq: 1
start_time: 2026-07-27T09:30:00+02:00
end_time: 2026-07-27T09:34:00+02:00
language: pt
---

# 2026-07-27 09:30

[09:30:05 · mic] hello
"""


@pytest.fixture
def tz_store(tmp_path: Path) -> PassageStore:
    """A passage whose transcript on disk records a +02:00 offset."""
    from datetime import timezone as _tz

    md = tmp_path / "093000_ab12_001.md"
    md.write_text(_TRANSCRIPT, encoding="utf-8")
    recorded = datetime(2026, 7, 27, 9, 30, 5, tzinfo=_tz(timedelta(hours=2)))
    s = PassageStore.open(tmp_path / "tz.db", embedding_model="hashing", dim=_EMB.dim)
    p = Passage(
        uid=f"{md}#0",
        text="hello",
        start=recorded,
        end=recorded + timedelta(minutes=2),
        sources=["mic"],
        session_id="20260727T093000_ab12",
        day=20260727,
        path=str(md),
        title="t",
    )
    s.upsert(str(md), "h", [p], _EMB.embed_passages([p.text]))
    return s


def test_recording_offset_read_from_frontmatter(tmp_path: Path) -> None:
    from huske.mcp.tools import recording_utc_offset

    md = tmp_path / "t.md"
    md.write_text(_TRANSCRIPT, encoding="utf-8")
    assert recording_utc_offset(str(md)) == timedelta(hours=2)


def test_recording_offset_handles_negative_and_missing(tmp_path: Path) -> None:
    from huske.mcp.tools import recording_utc_offset

    west = tmp_path / "west.md"
    west.write_text(_TRANSCRIPT.replace("+02:00", "-03:00"), encoding="utf-8")
    assert recording_utc_offset(str(west)) == timedelta(hours=-3)
    assert recording_utc_offset(str(tmp_path / "absent.md")) is None


def test_recap_clock_is_the_recording_zone(
    tz_store: PassageStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Pretend the reader is a VPS in UTC; the answer must still say 09:30."""
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    try:
        result = recap(tz_store, None)
        item = result["days"][0]["sessions"][0]
        assert item["started"] == "09:30"
        assert item["items"][0]["time"] == "09:30"
    finally:
        monkeypatch.delenv("TZ", raising=False)
        time.tzset()


def test_fetch_time_range_is_the_recording_zone(
    tz_store: PassageStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    from huske.mcp.tools import fetch_transcript

    monkeypatch.setenv("TZ", "America/Sao_Paulo")
    time.tzset()
    try:
        uid = tz_store.in_day_range()[0].uid
        fetched = fetch_transcript(tz_store, None, uid)
        assert "+02:00" in fetched["metadata"]["time_range"]
        assert "T09:30" in fetched["metadata"]["time_range"]
    finally:
        monkeypatch.delenv("TZ", raising=False)
        time.tzset()
