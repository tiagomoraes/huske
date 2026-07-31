"""Bounded-memory SQLite index: FTS5 by default, hybrid dense search optionally."""

from __future__ import annotations

import hashlib
import heapq
import re
import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol

from huske_mcp.transcripts import (
    TranscriptError,
    iter_transcript_paths,
    parse_transcript,
    window_transcript,
)

_TOKEN = re.compile(r"\w{2,}", re.UNICODE)
_SCHEMA = 1


class Embedder(Protocol):
    model_id: str

    def encode(self, texts: list[str]) -> list[bytes]: ...

    def encode_query(self, text: str) -> Any: ...

    def similarity(self, query: Any, vectors: list[bytes]) -> list[float]: ...


@dataclass(frozen=True)
class IndexSummary:
    seen: int
    indexed: int
    removed: int
    passages: int
    failed: int


class TranscriptIndex:
    def __init__(self, database_path: Path, *, embedder: Embedder | None = None) -> None:
        database_path.parent.mkdir(parents=True, exist_ok=True)
        self.database_path = database_path
        self.embedder = embedder
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(database_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.execute("PRAGMA busy_timeout=5000")
        self._conn.execute("PRAGMA cache_size=-8192")
        self._conn.execute("PRAGMA mmap_size=33554432")
        self._create_schema()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def refresh(self, transcript_root: Path) -> IndexSummary:
        with self._lock:
            paths = iter_transcript_paths(transcript_root)
            present: set[str] = set()
            indexed = failed = passages = 0
            for path in paths:
                rel = path.relative_to(transcript_root).as_posix()
                present.add(rel)
                digest = _sha256(path)
                current = self._conn.execute(
                    "SELECT sha256, embedding_model FROM documents WHERE path = ?",
                    (rel,),
                ).fetchone()
                model = self.embedder.model_id if self.embedder else ""
                if (
                    current
                    and current["sha256"] == digest
                    and current["embedding_model"] == model
                ):
                    continue
                try:
                    count = self._index_one(path, transcript_root, digest)
                except (OSError, TranscriptError, ValueError):
                    # A malformed replacement must never leave stale text
                    # searchable under the same canonical path.
                    with self._conn:
                        self._conn.execute(
                            "DELETE FROM documents WHERE path = ?", (rel,)
                        )
                    failed += 1
                    continue
                indexed += 1
                passages += count

            existing = {
                str(row[0])
                for row in self._conn.execute("SELECT path FROM documents").fetchall()
            }
            missing = sorted(existing - present)
            with self._conn:
                self._conn.executemany(
                    "DELETE FROM documents WHERE path = ?", ((path,) for path in missing)
                )
            return IndexSummary(
                seen=len(paths),
                indexed=indexed,
                removed=len(missing),
                passages=passages,
                failed=failed,
            )

    def search(
        self,
        query: str,
        *,
        date_from: str | None = None,
        date_to: str | None = None,
        source: str | None = None,
        session: str | None = None,
        limit: int = 8,
    ) -> dict[str, Any]:
        limit = max(1, min(50, int(limit)))
        with self._lock:
            lexical = self._lexical(
                query,
                date_from=date_from,
                date_to=date_to,
                source=source,
                session=session,
                limit=max(limit * 4, 30),
            )
            ranked = lexical
            mode = "fts5"
            if self.embedder is not None:
                semantic = self._semantic(
                    query,
                    date_from=date_from,
                    date_to=date_to,
                    source=source,
                    session=session,
                    limit=max(limit * 4, 30),
                )
                ranked = _rrf(lexical, semantic)
                mode = "hybrid"
            rows = ranked[:limit]
            return {
                "mode": mode,
                "results": [self._result(row) for row in rows],
            }

    def fetch(self, passage_id: int, *, context: int = 0) -> dict[str, Any]:
        context = max(0, min(5, int(context)))
        with self._lock:
            row = self._conn.execute(
                """SELECT p.*, d.session_id, d.language
                   FROM passages p JOIN documents d ON d.path = p.document_path
                   WHERE p.id = ?""",
                (passage_id,),
            ).fetchone()
            if row is None:
                raise ValueError(f"unknown passage id: {passage_id}")
            neighbors = self._conn.execute(
                """SELECT text FROM passages
                   WHERE document_path = ? AND ordinal BETWEEN ? AND ?
                   ORDER BY ordinal""",
                (
                    row["document_path"],
                    row["ordinal"] - context,
                    row["ordinal"] + context,
                ),
            ).fetchall()
            return {
                "id": str(row["id"]),
                "title": row["title"],
                "text": "\n\n".join(str(item["text"]) for item in neighbors),
                "metadata": {
                    "path": row["document_path"],
                    "session": row["session_id"],
                    "language": row["language"],
                    "start_time": row["start_time"],
                    "end_time": row["end_time"],
                    "sources": row["sources"],
                },
            }

    def recap(
        self,
        *,
        date_from: str | None = None,
        date_to: str | None = None,
        limit: int = 100,
    ) -> dict[str, Any]:
        limit = max(1, min(400, int(limit)))
        clauses, params = _filters(date_from, date_to, None, None, alias="p")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._lock:
            rows = self._conn.execute(
                f"""SELECT p.*, d.session_id
                    FROM passages p JOIN documents d ON d.path = p.document_path
                    {where}
                    ORDER BY p.start_time, p.id LIMIT ?""",
                (*params, limit + 1),
            ).fetchall()
        truncated = len(rows) > limit
        rows = rows[:limit]
        return {
            "items": [
                {
                    "id": str(row["id"]),
                    "time": row["start_time"],
                    "session": row["session_id"],
                    "sources": row["sources"],
                    "text": row["text"],
                }
                for row in rows
            ],
            "truncated": truncated,
        }

    def overview(self, *, recent_days: int = 14) -> dict[str, Any]:
        recent_days = max(1, min(365, int(recent_days)))
        with self._lock:
            documents = self._conn.execute(
                """SELECT COUNT(*) AS transcripts,
                          MIN(day) AS first_day, MAX(day) AS last_day
                   FROM documents"""
            ).fetchone()
            passage_count = int(
                self._conn.execute("SELECT COUNT(*) FROM passages").fetchone()[0]
            )
            days = self._conn.execute(
                """SELECT day, COUNT(*) AS passages,
                          COUNT(DISTINCT document_path) AS transcripts
                   FROM passages GROUP BY day ORDER BY day DESC LIMIT ?""",
                (recent_days,),
            ).fetchall()
        return {
            "passages": passage_count,
            "transcripts": documents["transcripts"],
            "first_day": documents["first_day"],
            "last_day": documents["last_day"],
            "recent_days": [dict(row) for row in days],
            "semantic": self.embedder is not None,
        }

    def _index_one(self, path: Path, root: Path, digest: str) -> int:
        transcript = parse_transcript(path, root)
        passages = window_transcript(transcript)
        vectors: list[bytes] = []
        if self.embedder and passages:
            vectors = self.embedder.encode([passage.text for passage in passages])
        model = self.embedder.model_id if self.embedder else ""
        day = transcript.start.date().isoformat()
        with self._conn:
            self._conn.execute("DELETE FROM documents WHERE path = ?", (transcript.relative_path,))
            self._conn.execute(
                """INSERT INTO documents
                   (path, sha256, session_id, start_time, end_time, day, language,
                    embedding_model)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    transcript.relative_path,
                    digest,
                    transcript.session_id,
                    transcript.start.isoformat(),
                    transcript.end.isoformat(),
                    day,
                    transcript.language,
                    model,
                ),
            )
            for index, passage in enumerate(passages):
                cursor = self._conn.execute(
                    """INSERT INTO passages
                       (document_path, ordinal, title, text, start_time, end_time,
                        day, sources)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        transcript.relative_path,
                        passage.ordinal,
                        passage.title,
                        passage.text,
                        passage.start.isoformat(),
                        passage.end.isoformat(),
                        day,
                        passage.sources,
                    ),
                )
                if vectors:
                    self._conn.execute(
                        "INSERT INTO embeddings (passage_id, model, vector) VALUES (?, ?, ?)",
                        (cursor.lastrowid, model, vectors[index]),
                    )
        return len(passages)

    def _lexical(self, query: str, **filters: Any) -> list[sqlite3.Row]:
        terms = _TOKEN.findall(query.lower())
        if not terms:
            return []
        match = " OR ".join(f'"{term}"' for term in terms[:20])
        clauses, params = _filters(
            filters["date_from"],
            filters["date_to"],
            filters["source"],
            filters["session"],
            alias="p",
        )
        clauses.insert(0, "passages_fts MATCH ?")
        return self._conn.execute(
            f"""SELECT p.*, d.session_id, bm25(passages_fts, 1.5, 1.0) AS rank
                FROM passages_fts
                JOIN passages p ON p.id = passages_fts.rowid
                JOIN documents d ON d.path = p.document_path
                WHERE {' AND '.join(clauses)}
                ORDER BY rank LIMIT ?""",
            (match, *params, filters["limit"]),
        ).fetchall()

    def _semantic(self, query: str, **filters: Any) -> list[sqlite3.Row]:
        if self.embedder is None:
            return []
        clauses, params = _filters(
            filters["date_from"],
            filters["date_to"],
            filters["source"],
            filters["session"],
            alias="p",
        )
        clauses.append("e.model = ?")
        params.append(self.embedder.model_id)
        where = " AND ".join(clauses)
        cursor = self._conn.execute(
            f"""SELECT p.*, d.session_id, e.vector
                FROM embeddings e
                JOIN passages p ON p.id = e.passage_id
                JOIN documents d ON d.path = p.document_path
                WHERE {where}""",
            params,
        )
        query_vector = self.embedder.encode_query(query)
        best: list[tuple[float, int, sqlite3.Row]] = []
        while batch := cursor.fetchmany(256):
            scores = self.embedder.similarity(
                query_vector, [bytes(row["vector"]) for row in batch]
            )
            for row, score in zip(batch, scores, strict=True):
                item = (score, int(row["id"]), row)
                if len(best) < filters["limit"]:
                    heapq.heappush(best, item)
                elif item[:2] > best[0][:2]:
                    heapq.heapreplace(best, item)
        return [item[2] for item in sorted(best, reverse=True)]

    @staticmethod
    def _result(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": str(row["id"]),
            "title": row["title"],
            "url": f"huske://transcript/{row['document_path']}#passage-{row['ordinal']}",
            "text": row["text"],
            "metadata": {
                "path": row["document_path"],
                "session": row["session_id"],
                "start_time": row["start_time"],
                "end_time": row["end_time"],
                "sources": row["sources"],
            },
        }

    def _create_schema(self) -> None:
        with self._conn:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS documents (
                    path TEXT PRIMARY KEY,
                    sha256 TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    start_time TEXT NOT NULL,
                    end_time TEXT NOT NULL,
                    day TEXT NOT NULL,
                    language TEXT NOT NULL,
                    embedding_model TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS passages (
                    id INTEGER PRIMARY KEY,
                    document_path TEXT NOT NULL REFERENCES documents(path) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    text TEXT NOT NULL,
                    start_time TEXT NOT NULL,
                    end_time TEXT NOT NULL,
                    day TEXT NOT NULL,
                    sources TEXT NOT NULL,
                    UNIQUE(document_path, ordinal)
                );
                CREATE INDEX IF NOT EXISTS idx_passages_day ON passages(day);
                CREATE INDEX IF NOT EXISTS idx_passages_document ON passages(document_path, ordinal);
                CREATE VIRTUAL TABLE IF NOT EXISTS passages_fts USING fts5(
                    title, text, content='passages', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER IF NOT EXISTS passages_ai AFTER INSERT ON passages BEGIN
                    INSERT INTO passages_fts(rowid, title, text)
                    VALUES (new.id, new.title, new.text);
                END;
                CREATE TRIGGER IF NOT EXISTS passages_ad AFTER DELETE ON passages BEGIN
                    INSERT INTO passages_fts(passages_fts, rowid, title, text)
                    VALUES ('delete', old.id, old.title, old.text);
                END;
                CREATE TABLE IF NOT EXISTS embeddings (
                    passage_id INTEGER PRIMARY KEY REFERENCES passages(id) ON DELETE CASCADE,
                    model TEXT NOT NULL,
                    vector BLOB NOT NULL
                );
                """
            )
            existing = self._conn.execute(
                "SELECT value FROM metadata WHERE key = 'schema'"
            ).fetchone()
            if existing and int(existing[0]) != _SCHEMA:
                raise RuntimeError("unsupported index schema; remove index.sqlite3 to rebuild")
            self._conn.execute(
                "INSERT OR REPLACE INTO metadata(key, value) VALUES ('schema', ?)",
                (str(_SCHEMA),),
            )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(128 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _filters(
    date_from: str | None,
    date_to: str | None,
    source: str | None,
    session: str | None,
    *,
    alias: str,
) -> tuple[list[str], list[Any]]:
    clauses: list[str] = []
    params: list[Any] = []
    for value in (date_from, date_to):
        if value:
            datetime.strptime(value, "%Y-%m-%d")
    if date_from:
        clauses.append(f"{alias}.day >= ?")
        params.append(date_from)
    if date_to:
        clauses.append(f"{alias}.day <= ?")
        params.append(date_to)
    if source:
        normalized = "mic" if source.lower() in {"mic", "microphone"} else source.lower()
        clauses.append(f"instr(',' || {alias}.sources || ',', ',' || ? || ',') > 0")
        params.append(normalized)
    if session:
        clauses.append("d.session_id = ?")
        params.append(session)
    return clauses, params


def _rrf(lexical: list[sqlite3.Row], semantic: list[sqlite3.Row]) -> list[sqlite3.Row]:
    scores: dict[int, float] = {}
    rows: dict[int, sqlite3.Row] = {}
    for ranking in (lexical, semantic):
        for position, row in enumerate(ranking, start=1):
            identifier = int(row["id"])
            rows[identifier] = row
            scores[identifier] = scores.get(identifier, 0.0) + 1.0 / (60 + position)
    return [rows[key] for key in sorted(scores, key=lambda key: scores[key], reverse=True)]
