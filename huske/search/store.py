"""sqlite-vec passage store: one transactional file, filtered KNN.

Schema (see docs/adr/0002-local-search-stack.md):

- ``passages`` is a ``vec0`` virtual table. ``session_id`` is a partition key;
  ``day``/``has_mic``/``has_system``/``start_ms``/``end_ms``/``uid``/``path``
  are indexed metadata columns (filterable, incl. range on ``day``);
  ``text``/``title``/``sources`` are auxiliary columns (returned, not filtered).
- ``index_meta`` records ``embedding_model`` + ``dim`` + ``schema_version`` so a
  model/dimension change is refused rather than silently mixing vector spaces
  (the policy from the grilling session). ``indexed_files`` tracks
  ``(path, content_hash, model_id)`` for incremental indexing.

``sqlite-vec`` is imported lazily so importing this module is safe without the
``huske[mcp]`` extra.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from huske.search.models import Passage, SearchHit

SCHEMA_VERSION = 1


class StoreUnavailable(RuntimeError):
    """sqlite-vec is missing, unusable, or the index does not yet exist."""


class ModelMismatchError(RuntimeError):
    """The index was built with a different embedding model / dimension / schema."""


def _require_sqlite_vec() -> object:
    try:
        import sqlite_vec
    except ImportError as exc:
        raise StoreUnavailable(
            "sqlite-vec is not installed. Install the search extra:\n"
            "  pip install 'huske[mcp]'"
        ) from exc
    return sqlite_vec


def _serialize(sqlite_vec: object, vec: Sequence[float]) -> bytes:
    return sqlite_vec.serialize_float32(list(vec))  # type: ignore[attr-defined,no-any-return]


def _epoch_ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def _uid_index(hit: SearchHit) -> int:
    """Integer suffix of a passage uid (``<key>#<n>``), for numeric ordering."""
    _, _, idx = hit.uid.rpartition("#")
    return int(idx) if idx.isdigit() else 0


class PassageStore:
    """Read/write handle to the passage index. Use :meth:`open`."""

    def __init__(self, conn: sqlite3.Connection, sqlite_vec: object, model_id: str, dim: int) -> None:
        self._conn = conn
        self._sqlite_vec = sqlite_vec
        self.model_id = model_id
        self.dim = dim

    # -- lifecycle ---------------------------------------------------------

    @classmethod
    def open(
        cls,
        db_path: Path,
        *,
        embedding_model: str | None = None,
        dim: int | None = None,
        create: bool = True,
    ) -> PassageStore:
        """Open (and optionally create) the store at ``db_path``.

        Raises :class:`ModelMismatchError` if an existing index was built with a
        different model/dim/schema. Raises :class:`StoreUnavailable` if the
        index is empty and we lack the model/dim needed to create it.
        """
        sqlite_vec = _require_sqlite_vec()
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(db_path))
        try:
            conn.enable_load_extension(True)
            sqlite_vec.load(conn)  # type: ignore[attr-defined]
            conn.enable_load_extension(False)
        except (AttributeError, sqlite3.OperationalError) as exc:
            conn.close()
            raise StoreUnavailable(
                f"could not load sqlite-vec extension: {exc}. "
                "This Python build may have SQLite extension loading disabled."
            ) from exc

        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS index_meta (key TEXT PRIMARY KEY, value TEXT)"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS indexed_files ("
            "path TEXT PRIMARY KEY, content_hash TEXT, model_id TEXT, "
            "passages INTEGER, indexed_at TEXT)"
        )

        meta = dict(conn.execute("SELECT key, value FROM index_meta").fetchall())
        has_table = (
            conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='passages'"
            ).fetchone()
            is not None
        )

        if meta and has_table:
            stored_schema = int(meta.get("schema_version", "0"))
            stored_model = meta.get("embedding_model", "")
            stored_dim = int(meta.get("dim", "0"))
            if stored_schema != SCHEMA_VERSION:
                conn.close()
                raise ModelMismatchError(
                    f"index schema v{stored_schema} != current v{SCHEMA_VERSION}. "
                    "Run `huske index --rebuild`."
                )
            if embedding_model is not None and stored_model != embedding_model:
                conn.close()
                raise ModelMismatchError(
                    f"index built with embedding model '{stored_model}', but config "
                    f"requests '{embedding_model}'. Run `huske index --rebuild`."
                )
            if dim is not None and stored_dim != dim:
                conn.close()
                raise ModelMismatchError(
                    f"index dimension {stored_dim} != model dimension {dim}. "
                    "Run `huske index --rebuild`."
                )
            return cls(conn, sqlite_vec, stored_model, stored_dim)

        # Fresh (or partial) index.
        if not create or embedding_model is None or dim is None:
            conn.close()
            raise StoreUnavailable(
                f"no passage index at {db_path}. Run `huske index` first."
            )
        cls._create_schema(conn, dim)
        conn.execute(
            "INSERT OR REPLACE INTO index_meta(key, value) VALUES "
            "('embedding_model', ?), ('dim', ?), ('schema_version', ?)",
            (embedding_model, str(dim), str(SCHEMA_VERSION)),
        )
        conn.commit()
        return cls(conn, sqlite_vec, embedding_model, dim)

    @staticmethod
    def _create_schema(conn: sqlite3.Connection, dim: int) -> None:
        conn.execute(
            f"""
            CREATE VIRTUAL TABLE passages USING vec0(
                embedding float[{dim}] distance_metric=cosine,
                session_id text partition key,
                day integer,
                has_mic integer,
                has_system integer,
                start_ms integer,
                end_ms integer,
                uid text,
                path text,
                +text text,
                +title text,
                +sources text
            )
            """
        )

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> PassageStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- incremental bookkeeping ------------------------------------------

    def is_indexed(self, path: str, content_hash: str) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM indexed_files WHERE path=? AND content_hash=? AND model_id=?",
            (path, content_hash, self.model_id),
        ).fetchone()
        return row is not None

    def delete_path(self, path: str) -> None:
        self._conn.execute("DELETE FROM passages WHERE path=?", (path,))
        self._conn.execute("DELETE FROM indexed_files WHERE path=?", (path,))

    # -- writes ------------------------------------------------------------

    def upsert(
        self,
        path: str,
        content_hash: str,
        passages: Sequence[Passage],
        embeddings: Sequence[Sequence[float]],
    ) -> int:
        """Replace all passages for ``path`` with the given ones. Returns count."""
        if len(passages) != len(embeddings):
            raise ValueError("passages and embeddings length mismatch")
        self.delete_path(path)
        for p, emb in zip(passages, embeddings, strict=True):
            if len(emb) != self.dim:
                raise ValueError(f"embedding dim {len(emb)} != store dim {self.dim}")
            self._conn.execute(
                "INSERT INTO passages("
                "embedding, session_id, day, has_mic, has_system, "
                "start_ms, end_ms, uid, path, text, title, sources) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    _serialize(self._sqlite_vec, emb),
                    p.session_id,
                    p.day,
                    int(p.has_mic),
                    int(p.has_system),
                    _epoch_ms(p.start),
                    _epoch_ms(p.end),
                    p.uid,
                    p.path,
                    p.text,
                    p.title,
                    ",".join(p.sources),
                ),
            )
        self._conn.execute(
            "INSERT OR REPLACE INTO indexed_files(path, content_hash, model_id, passages, indexed_at) "
            "VALUES (?,?,?,?,?)",
            (
                path,
                content_hash,
                self.model_id,
                len(passages),
                datetime.now(UTC).isoformat(timespec="seconds"),
            ),
        )
        self._conn.commit()
        return len(passages)

    # -- reads -------------------------------------------------------------

    def search(
        self,
        query_embedding: Sequence[float],
        k: int = 8,
        *,
        day_from: int | None = None,
        day_to: int | None = None,
        source: str | None = None,
        session_id: str | None = None,
    ) -> list[SearchHit]:
        where = ["embedding MATCH ?", "k = ?"]
        params: list[object] = [_serialize(self._sqlite_vec, query_embedding), int(k)]
        if session_id:
            where.append("session_id = ?")
            params.append(session_id)
        if day_from is not None:
            where.append("day >= ?")
            params.append(day_from)
        if day_to is not None:
            where.append("day <= ?")
            params.append(day_to)
        if source == "mic":
            where.append("has_mic = 1")
        elif source == "system":
            where.append("has_system = 1")

        sql = (
            "SELECT distance, uid, title, text, path, session_id, day, "
            "start_ms, end_ms, sources FROM passages WHERE " + " AND ".join(where)
        )
        rows = self._conn.execute(sql, params).fetchall()
        return [self._row_to_hit(r, distance=r[0]) for r in rows]

    def get_by_uid(self, uid: str) -> SearchHit | None:
        row = self._conn.execute(
            "SELECT 0.0, uid, title, text, path, session_id, day, "
            "start_ms, end_ms, sources FROM passages WHERE uid = ?",
            (uid,),
        ).fetchone()
        return self._row_to_hit(row, distance=0.0) if row else None

    def neighbors(self, uid: str, *, before: int = 1, after: int = 1) -> list[SearchHit]:
        """Adjacent passages from the same transcript, by uid suffix index."""
        base, _, idx_s = uid.rpartition("#")
        if not idx_s.isdigit():
            return []
        idx = int(idx_s)
        wanted = [f"{base}#{i}" for i in range(idx - before, idx + after + 1) if i >= 0 and i != idx]
        if not wanted:
            return []
        placeholders = ",".join("?" for _ in wanted)
        rows = self._conn.execute(
            "SELECT 0.0, uid, title, text, path, session_id, day, start_ms, end_ms, sources "
            f"FROM passages WHERE uid IN ({placeholders})",
            wanted,
        ).fetchall()
        hits = [self._row_to_hit(r, distance=0.0) for r in rows]
        hits.sort(key=_uid_index)
        return hits

    def stats(self) -> dict[str, object]:
        passages = self._conn.execute("SELECT count(*) FROM passages").fetchone()[0]
        files = self._conn.execute("SELECT count(*) FROM indexed_files").fetchone()[0]
        return {
            "embedding_model": self.model_id,
            "dim": self.dim,
            "schema_version": SCHEMA_VERSION,
            "passages": int(passages),
            "files": int(files),
        }

    @staticmethod
    def _row_to_hit(row: Sequence[Any], *, distance: float) -> SearchHit:
        (_dist, uid, title, text, path, session_id, day, start_ms, end_ms, sources) = row
        sources_list = [s for s in str(sources).split(",") if s]
        sim = 1.0 - float(distance)
        return SearchHit(
            uid=str(uid),
            title=str(title),
            url=f"file://{path}",
            text=str(text),
            score=round(max(0.0, sim), 4),
            session_id=str(session_id),
            day=int(day),
            start_ms=int(start_ms),
            end_ms=int(end_ms),
            sources=sources_list,
            path=str(path),
        )
