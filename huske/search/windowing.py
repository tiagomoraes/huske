"""Window a transcript's runs into Passages.

Passages are built by grouping consecutive runs **by time regardless of
source** (see CONTEXT.md and the multi-source decision), targeting ~320 tokens
with a hard cap safely under the embedding model's 512-token limit, breaking at
large time gaps, and carrying a bounded sentence-tail overlap into the next
window for context continuity.

Token counting is injectable: production passes the embedding model's real
tokenizer; tests/fallback use a conservative word-based heuristic. Changing
these constants changes passage boundaries and therefore requires a re-index —
they are versioned via the store's schema version.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from datetime import datetime

from huske.search.models import Passage, Run, TranscriptDoc

TARGET_TOKENS = 320
MAX_TOKENS = 480  # stay safely under multilingual-e5's 512-token window
MAX_GAP_SECONDS = 120.0  # don't span a long silence within one passage

_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?…])\s+")
TokenCounter = Callable[[str], int]


def _heuristic_tokens(text: str) -> int:
    """Conservative multilingual estimate (~1.5 tokens/word)."""
    return max(1, round(len(text.split()) * 1.5))


def _sources_in_order(runs: list[Run]) -> list[str]:
    out: list[str] = []
    for r in runs:
        if r.source and r.source not in out:
            out.append(r.source)
    return out


def _last_sentence(text: str, *, max_words: int = 40) -> str:
    parts = [p for p in _SENTENCE_SPLIT_RE.split(text.strip()) if p]
    if not parts:
        return ""
    tail = parts[-1]
    words = tail.split()
    if len(words) > max_words:
        tail = " ".join(words[-max_words:])
    return tail


def _split_oversized(text: str, target: int, count: TokenCounter) -> list[str]:
    """Split a too-long run into <=target-token pieces, by sentence then words."""
    pieces: list[str] = []
    cur: list[str] = []
    cur_tok = 0

    def flush() -> None:
        nonlocal cur, cur_tok
        if cur:
            pieces.append(" ".join(cur).strip())
            cur = []
            cur_tok = 0

    for sentence in _SENTENCE_SPLIT_RE.split(text.strip()):
        sentence = sentence.strip()
        if not sentence:
            continue
        stok = count(sentence)
        if stok > target:
            flush()
            words = sentence.split()
            buf: list[str] = []
            for w in words:
                buf.append(w)
                if count(" ".join(buf)) >= target:
                    pieces.append(" ".join(buf))
                    buf = []
            if buf:
                pieces.append(" ".join(buf))
            continue
        if cur and cur_tok + stok > target:
            flush()
        cur.append(sentence)
        cur_tok += stok
    flush()
    return pieces or [text.strip()]


def _day_int(dt: datetime) -> int:
    return int(dt.strftime("%Y%m%d"))


def _title(start: datetime, end: datetime, sources: list[str]) -> str:
    label = "+".join(sources) if sources else "speech"
    return f"{start.date().isoformat()} {start:%H:%M}–{end:%H:%M} · {label}"  # noqa: RUF001


def window(
    doc: TranscriptDoc,
    *,
    count_tokens: TokenCounter | None = None,
    doc_key: str | None = None,
    target_tokens: int = TARGET_TOKENS,
    max_tokens: int = MAX_TOKENS,
    max_gap_seconds: float = MAX_GAP_SECONDS,
) -> list[Passage]:
    """Window ``doc`` into Passages. ``doc_key`` seeds passage uids (defaults to path)."""
    count = count_tokens or _heuristic_tokens
    key = doc_key if doc_key is not None else str(doc.path)
    passages: list[Passage] = []
    cur: list[Run] = []
    cur_tok = 0
    prev_tail = ""  # overlap carry; reset on gap break

    def make(text: str, start: datetime, end: datetime, sources: list[str]) -> Passage:
        idx = len(passages)
        return Passage(
            uid=f"{key}#{idx}",
            text=text,
            start=start,
            end=end,
            sources=sources,
            session_id=doc.session_id,
            day=_day_int(start),
            # Must equal the upsert/delete key (see PassageStore.delete_path),
            # otherwise incremental re-index can't remove stale rows.
            path=key,
            title=_title(start, end, sources),
        )

    def emit() -> None:
        nonlocal cur, cur_tok, prev_tail
        if not cur:
            return
        body = " ".join(r.text for r in cur).strip()
        text = body
        if prev_tail:
            candidate = f"{prev_tail} {body}".strip()
            if count(candidate) <= max_tokens:
                text = candidate
        sources = _sources_in_order(cur)
        passages.append(make(text, cur[0].start, cur[-1].end or cur[-1].start, sources))
        prev_tail = _last_sentence(body)
        cur = []
        cur_tok = 0

    for run in doc.runs:
        if not run.text.strip():
            continue
        rtok = count(run.text)

        if cur and (run.start - (cur[-1].end or cur[-1].start)).total_seconds() > max_gap_seconds:
            emit()
            prev_tail = ""  # do not carry context across a silence

        if rtok > max_tokens:
            emit()
            prev_tail = ""
            src = [run.source] if run.source else []
            for piece in _split_oversized(run.text, target_tokens, count):
                passages.append(make(piece, run.start, run.end or run.start, src))
            continue

        if cur and cur_tok + rtok > target_tokens:
            emit()

        cur.append(run)
        cur_tok += rtok

    emit()
    return passages
