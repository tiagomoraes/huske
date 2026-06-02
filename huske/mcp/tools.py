"""Pure search/fetch logic behind the MCP tools.

These functions implement ChatGPT's connector contract — ``search`` returns
``{"results": [{"id","title","url"}]}`` and ``fetch`` returns
``{"id","title","text","url","metadata"}`` — while ``search`` also accepts
optional ``date_from``/``date_to``/``source``/``session`` filters that Claude
can use and ChatGPT simply omits (the portable design from the grilling
session). Kept free of any ``mcp`` import so they're unit-testable on their own.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from huske.search.embedder import Embedder
from huske.search.store import PassageStore

MAX_K = 50
DEFAULT_K = 8


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


def _fmt_time_range(start_ms: int, end_ms: int) -> str:
    start = datetime.fromtimestamp(start_ms / 1000, tz=UTC).astimezone()
    end = datetime.fromtimestamp(end_ms / 1000, tz=UTC).astimezone()
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
    embedding = embedder.embed_query(query)
    hits = store.search(
        embedding,
        k=_clamp_k(k),
        day_from=_date_to_day(date_from),
        day_to=_date_to_day(date_to),
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
            "session": hit.session_id,
            "day": str(hit.day),
            "time_range": _fmt_time_range(hit.start_ms, hit.end_ms),
            "sources": ",".join(hit.sources),
            "path": hit.path,
        },
    }


def _uid_index(uid: str) -> int:
    _, _, idx = uid.rpartition("#")
    return int(idx) if idx.isdigit() else 0
