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
            "time_range": _fmt_time_range(hit.start_ms, hit.end_ms),
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
            "time_range": _fmt_time_range(hit.start_ms, hit.end_ms),
            "sources": ",".join(hit.sources),
            "path": hit.path,
        },
    }
