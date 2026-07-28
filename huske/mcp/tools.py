"""Pure search/fetch logic behind the MCP tools.

These functions implement ChatGPT's connector contract — ``search`` returns
``{"results": [{"id","title","url"}]}`` and ``fetch`` returns
``{"id","title","text","url","metadata"}`` — while ``search`` also accepts
optional ``date_from``/``date_to``/``source``/``session`` filters that Claude
can use and ChatGPT simply omits (the portable design from the grilling
session). Kept free of any ``mcp`` import so they're unit-testable on their own.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any, cast

from huske.search.embedder import Embedder
from huske.search.store import PassageStore

MAX_K = 50
DEFAULT_K = 8

# Retrieval granularity: distilled Statements (denser, more searchable) vs raw
# transcript Passages. "auto" prefers Statements when that index is populated.
Granularity = str  # "auto" | "statement" | "passage"


class UnknownPassageError(ValueError):
    """fetch() was given an id that is not in the index."""


def _date_to_day(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    return int(datetime.strptime(value, "%Y-%m-%d").strftime("%Y%m%d"))


def _normalize_source(value: str | None) -> str | None:
    if not value:
        return None
    v = value.strip().lower()
    if v in ("mic", "microphone"):
        return "mic"
    if v in ("system", "sys"):
        return "system"
    return None


def _clamp_k(k: int) -> int:
    return max(1, min(MAX_K, int(k)))


# The index stores epoch milliseconds — timezone-free by design, so range
# filtering is a plain integer comparison. Rendering a *clock* from that needs a
# zone, and the obvious `.astimezone()` picks the **reader's**. That was
# invisible while the only reader ran on the recording Mac, and silently wrong
# the moment a VPS in another zone answers: a 09:30 meeting is reported at 04:30,
# which is worse than no timestamp at all.
#
# The transcript's frontmatter carries the offset it was recorded at, and the
# `.md` is the published contract every consumer reads (ADR 0004) — so take it
# from there. Only the offset is needed, so this reads the head of the file
# rather than parsing YAML, and caches per path (a finalized transcript is
# immutable, so the offset never changes).
_START_TIME_OFFSET_RE = re.compile(
    r"^start_time:\s*\S*?(?P<sign>[+-])(?P<hh>\d{2}):(?P<mm>\d{2})\s*$", re.MULTILINE
)


@lru_cache(maxsize=512)
def recording_utc_offset(path: str) -> timedelta | None:
    """The UTC offset ``path`` was recorded at, or ``None`` if undeterminable."""
    try:
        with Path(path).open(encoding="utf-8") as f:
            head = f.read(1024)
    except OSError:
        return None
    match = _START_TIME_OFFSET_RE.search(head)
    if match is None:
        return None
    delta = timedelta(hours=int(match["hh"]), minutes=int(match["mm"]))
    return -delta if match["sign"] == "-" else delta


def _as_recorded(ms: int, path: str | None) -> datetime:
    """Epoch ms rendered in the zone it was recorded in, falling back to local.

    The fallback only fires when the transcript is unreadable — which on a local
    install means the file moved, and cannot happen on a server that stores it.
    """
    utc = datetime.fromtimestamp(ms / 1000, tz=UTC)
    offset = recording_utc_offset(path) if path else None
    if offset is None:
        return utc.astimezone()
    return utc.astimezone(timezone(offset))


def _fmt_time_range(start_ms: int, end_ms: int, path: str | None = None) -> str:
    start = _as_recorded(start_ms, path)
    end = _as_recorded(end_ms, path)
    return f"{start.isoformat(timespec='seconds')} – {end.isoformat(timespec='seconds')}"  # noqa: RUF001


def search_passages(
    store: PassageStore,
    embedder: Embedder,
    query: str,
    *,
    date_from: str | None = None,
    date_to: str | None = None,
    source: str | None = None,
    session: str | None = None,
    k: int = DEFAULT_K,
) -> dict[str, Any]:
    """Semantic search → ChatGPT-shaped ``{"results": [...]}``."""
    try:
        day_from = _date_to_day(date_from)
        day_to = _date_to_day(date_to)
    except ValueError as exc:
        raise ValueError(f"invalid date: {exc}. Use YYYY-MM-DD format.") from exc
    embedding = embedder.embed_query(query)
    hits = store.search(
        embedding,
        k=_clamp_k(k),
        day_from=day_from,
        day_to=day_to,
        source=_normalize_source(source),
        session_id=session or None,
    )
    # Exactly {id, title, url} per ChatGPT's connector contract — extra keys
    # risk strict validation. Clients call `fetch` for the full text.
    return {"results": [{"id": h.uid, "title": h.title, "url": h.url} for h in hits]}


def fetch_passage(store: PassageStore, passage_id: str, *, context: int = 0) -> dict[str, Any]:
    """Fetch a passage (optionally with ±context neighbors) → ChatGPT-shaped dict."""
    hit = store.get_by_uid(passage_id)
    if hit is None:
        raise UnknownPassageError(f"unknown passage id: {passage_id!r}")

    text = hit.text
    if context > 0:
        neighbors = store.neighbors(passage_id, before=context, after=context)
        ordered = sorted([hit, *neighbors], key=lambda h: _uid_index(h.uid))
        text = "\n\n".join(h.text for h in ordered)

    return {
        "id": hit.uid,
        "title": hit.title,
        "text": text,
        "url": hit.url,
        "metadata": {
            "kind": "passage",
            "session": hit.session_id,
            "day": str(hit.day),
            "time_range": _fmt_time_range(hit.start_ms, hit.end_ms, hit.path),
            "sources": ",".join(hit.sources),
            "path": hit.path,
        },
    }


def _uid_index(uid: str) -> int:
    _, _, idx = uid.rpartition("#")
    return int(idx) if idx.isdigit() else 0


# --- Two-stage retrieval: distilled Statements → grounded transcript ---------
#
# When a statement store exists, `search` targets it (claims are denser and more
# searchable than conversational passages), and `fetch` on a statement returns
# the claim PLUS the verbatim source-transcript passages it was distilled from —
# the "search the index, then read the transcript for depth" flow. Statements
# are stored as Passage-shaped records, so both stores are ``PassageStore`` and
# the passage search/fetch helpers above are reused verbatim. See
# docs/adr/0005-llm-distillation.md.


def _normalize_granularity(value: str | None) -> str:
    v = (value or "auto").strip().lower()
    if v in ("statement", "statements"):
        return "statement"
    if v in ("passage", "passages"):
        return "passage"
    return "auto"


def _pick_store(
    passage_store: PassageStore,
    statement_store: PassageStore | None,
    granularity: str,
) -> PassageStore:
    if granularity == "passage":
        return passage_store
    if granularity == "statement":
        if statement_store is None:
            raise ValueError(
                "no statement index — run `huske distill` then `huske index`, "
                "or use granularity='passage'."
            )
        return statement_store
    # auto: prefer statements when that index has rows, else fall back to passages.
    if statement_store is not None and cast(int, statement_store.stats()["passages"]) > 0:
        return statement_store
    return passage_store


def search_transcripts(
    passage_store: PassageStore,
    statement_store: PassageStore | None,
    embedder: Embedder,
    query: str,
    *,
    granularity: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    source: str | None = None,
    session: str | None = None,
    k: int = DEFAULT_K,
) -> dict[str, Any]:
    """Semantic search over Statements (default) or Passages → ChatGPT shape."""
    store = _pick_store(passage_store, statement_store, _normalize_granularity(granularity))
    return search_passages(
        store,
        embedder,
        query,
        date_from=date_from,
        date_to=date_to,
        source=source,
        session=session,
        k=k,
    )


def fetch_transcript(
    passage_store: PassageStore,
    statement_store: PassageStore | None,
    id: str,
    *,
    context: int = 0,
) -> dict[str, Any]:
    """Fetch a Statement (grounded in its source transcript) or a Passage by id.

    A statement id resolves in the statement store; we return the claim plus the
    transcript passages overlapping its time range — so the caller reads the
    real words behind the claim. A passage id falls through to the passage fetch.
    """
    if statement_store is not None:
        hit = statement_store.get_by_uid(id)
        if hit is not None:
            return _fetch_statement(passage_store, hit)
    return fetch_passage(passage_store, id, context=context)


def _fetch_statement(passage_store: PassageStore, hit: Any) -> dict[str, Any]:
    grounding = passage_store.passages_in_range(hit.path, hit.start_ms, hit.end_ms, limit=4)
    text = hit.text
    if grounding:
        transcript = "\n\n".join(g.text for g in grounding)
        text = f"{hit.text}\n\n--- source transcript ---\n\n{transcript}"
    return {
        "id": hit.uid,
        "title": hit.title,
        "text": text,
        "url": hit.url,
        "metadata": {
            "kind": "statement",
            "session": hit.session_id,
            "day": str(hit.day),
            "time_range": _fmt_time_range(hit.start_ms, hit.end_ms, hit.path),
            "sources": ",".join(hit.sources),
            "path": hit.path,
        },
    }


# --- Time-scoped recall: recap + overview -----------------------------------
#
# `search` answers "what was said about X". It cannot answer "what happened
# yesterday", because a date range is not a semantic neighborhood: embedding the
# phrase "yesterday" and taking the nearest K returns whatever *sounds* like the
# word. Worse, an agent that only has `search` has to invent a query to find out
# anything at all, so the common case — "catch me up" — degrades into guesswork
# over a corpus the model cannot see the shape of.
#
# `overview` gives the model the map (what days exist, how dense they are) and
# `recap` returns a range whole, in the order it was said. Both are plain
# metadata scans: no embedding, so they work on a fresh index and cost nothing.

MAX_RECAP_ITEMS = 400
DEFAULT_RECAP_ITEMS = 80


def _fmt_day(day: int) -> str:
    return f"{day // 10000:04d}-{day // 100 % 100:02d}-{day % 100:02d}"


def _fmt_clock(ms: int, path: str | None = None) -> str:
    return _as_recorded(ms, path).strftime("%H:%M")


def _day_or_none(value: str | None) -> int | None:
    try:
        return _date_to_day(value)
    except ValueError as exc:
        raise ValueError(f"invalid date: {exc}. Use YYYY-MM-DD format.") from exc


def recap(
    passage_store: PassageStore,
    statement_store: PassageStore | None,
    *,
    date_from: str | None = None,
    date_to: str | None = None,
    source: str | None = None,
    session: str | None = None,
    granularity: str | None = None,
    max_items: int = DEFAULT_RECAP_ITEMS,
) -> dict[str, Any]:
    """Everything recorded in a date range, grouped by day and session.

    With no dates this resolves to the most recent day that actually has
    content — not the calendar's today. The server may sit in a different
    timezone from the Mac that recorded, and a weekend gap would otherwise
    return an empty digest that reads as "nothing was discussed".
    """
    store = _pick_store(passage_store, statement_store, _normalize_granularity(granularity))
    kind = "statement" if store is statement_store else "passage"

    day_from = _day_or_none(date_from)
    day_to = _day_or_none(date_to)
    resolved = ""
    if day_from is None and day_to is None:
        bounds = store.day_bounds()
        if bounds is None:
            return {
                "range": {"from": None, "to": None},
                "kind": kind,
                "days": [],
                "item_count": 0,
                "truncated": False,
                "note": "nothing is indexed yet — run `huske index`.",
            }
        day_from = day_to = bounds[1]
        resolved = "most recent day with recorded audio"

    limit = max(1, min(MAX_RECAP_ITEMS, int(max_items)))
    # Ask for one extra row so a full page is distinguishable from a truncated
    # one without a second count query.
    hits = store.in_day_range(
        day_from=day_from,
        day_to=day_to,
        source=_normalize_source(source),
        session_id=session or None,
        limit=limit + 1,
    )
    truncated = len(hits) > limit
    hits = hits[:limit]

    days: list[dict[str, Any]] = []
    for hit in hits:
        day_label = _fmt_day(hit.day)
        if not days or days[-1]["date"] != day_label:
            days.append({"date": day_label, "sessions": []})
        sessions: list[dict[str, Any]] = days[-1]["sessions"]
        if not sessions or sessions[-1]["session_id"] != hit.session_id:
            sessions.append(
                {
                    "session_id": hit.session_id,
                    "started": _fmt_clock(hit.start_ms, hit.path),
                    "transcript": hit.path,
                    "items": [],
                }
            )
        sessions[-1]["items"].append(
            {
                "id": hit.uid,
                "time": _fmt_clock(hit.start_ms, hit.path),
                "sources": ",".join(hit.sources),
                "text": hit.text,
            }
        )

    # Either bound may still be None: "everything since July 1st" is a normal
    # call, and an open end must be reported as open rather than invented.
    result: dict[str, Any] = {
        "range": {
            "from": _fmt_day(day_from) if day_from is not None else None,
            "to": _fmt_day(day_to) if day_to is not None else None,
        },
        "kind": kind,
        "days": days,
        "item_count": len(hits),
        "truncated": truncated,
    }
    if resolved:
        result["range"]["resolved_as"] = resolved
    if truncated:
        result["note"] = (
            f"showing the first {limit} of more — narrow the range, or raise max_items "
            f"(cap {MAX_RECAP_ITEMS})."
        )
    elif kind == "statement":
        result["note"] = (
            "these are distilled claims; `fetch` any id to read the verbatim transcript "
            "behind it."
        )
    return result


def overview(
    passage_store: PassageStore,
    statement_store: PassageStore | None,
    *,
    recent_days: int = 14,
) -> dict[str, Any]:
    """What the corpus contains: coverage, density, and the newest days.

    Orientation before retrieval. Without it a model cannot tell an empty index
    from an unlucky query, and cannot pick a plausible date range to recap.
    """
    stats = passage_store.stats()
    bounds = passage_store.day_bounds()
    counts = dict(passage_store.day_counts(limit=max(1, recent_days)))
    statement_counts: dict[int, int] = {}
    statement_total = 0
    if statement_store is not None:
        s_stats = statement_store.stats()
        statement_total = int(cast(int, s_stats["passages"]))
        statement_counts = dict(statement_store.day_counts(limit=max(1, recent_days)))

    days = sorted(set(counts) | set(statement_counts), reverse=True)[: max(1, recent_days)]
    return {
        "transcripts": int(cast(int, stats["files"])),
        "passages": int(cast(int, stats["passages"])),
        "statements": statement_total,
        "first_day": _fmt_day(bounds[0]) if bounds else None,
        "last_day": _fmt_day(bounds[1]) if bounds else None,
        "embedding_model": stats["embedding_model"],
        "recent_days": [
            {
                "date": _fmt_day(day),
                "passages": counts.get(day, 0),
                "statements": statement_counts.get(day, 0),
            }
            for day in days
        ],
        "note": (
            "days with no entry were not recorded. Use `recap` for a date range, "
            "`search` for a topic."
        ),
    }
