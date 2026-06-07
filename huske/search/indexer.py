"""Indexer: parse → window → embed → upsert.

The same ``Indexer.index_file`` backs both live indexing (the embed worker
during ``huske run``) and the ``huske index`` backfill — one code path, as
decided in docs/adr/0003-embed-worker-isolation.md.
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path

from huske.distill.models import StatementSidecar
from huske.distill.sidecar import read_sidecar
from huske.search.embedder import Embedder
from huske.search.models import Passage
from huske.search.parser import ParseError, parse_transcript
from huske.search.store import PassageStore
from huske.search.windowing import window

_STATEMENT_TITLE_MAX = 160


@dataclass
class IndexSummary:
    files_seen: int = 0
    files_indexed: int = 0
    files_skipped: int = 0
    files_failed: int = 0
    passages: int = 0
    errors: list[str] = field(default_factory=list)


def _content_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _release_embedder(embedder: Embedder) -> None:
    """Best-effort release of an embedder's reclaimable memory (e.g. the MLX
    buffer cache) between files, so a long backfill keeps a flat footprint.
    Tolerant of embedders/test doubles that don't implement ``release``.
    """
    release = getattr(embedder, "release", None)
    if callable(release):
        try:
            release()
        except Exception:
            pass


class Indexer:
    def __init__(self, store: PassageStore, embedder: Embedder) -> None:
        self._store = store
        self._embedder = embedder

    def index_file(self, path: Path, *, force: bool = False) -> int:
        """Index a single transcript. Returns passages written (0 if skipped).

        Incremental: a file whose content hash + model id already match is
        skipped unless ``force``. Re-indexing replaces the file's passages.
        """
        path = path.resolve()
        digest = _content_hash(path)
        key = str(path)
        if not force and self._store.is_indexed(key, digest):
            return 0

        doc = parse_transcript(path)
        passages = window(doc, count_tokens=self._embedder.count_tokens, doc_key=key)
        if not passages:
            # Empty/no-speech transcript: clear any stale passages, record the
            # hash so we don't re-parse it every pass.
            self._store.upsert(key, digest, [], [])
            return 0
        embeddings = self._embedder.embed_passages([p.text for p in passages])
        return self._store.upsert(key, digest, passages, embeddings)

    def index_paths(
        self,
        paths: Iterable[Path],
        *,
        force: bool = False,
        release_between_files: bool = False,
    ) -> IndexSummary:
        summary = IndexSummary()
        for path in paths:
            summary.files_seen += 1
            try:
                n = self.index_file(path, force=force)
            except ParseError as exc:
                summary.files_failed += 1
                summary.errors.append(str(exc))
                continue
            except Exception as exc:
                summary.files_failed += 1
                summary.errors.append(f"{path}: {exc}")
                continue
            finally:
                if release_between_files:
                    _release_embedder(self._embedder)
            if n > 0:
                summary.files_indexed += 1
                summary.passages += n
            else:
                summary.files_skipped += 1
        return summary

    def backfill(
        self,
        output_root: Path,
        *,
        force: bool = False,
        release_between_files: bool = False,
    ) -> IndexSummary:
        """Index every transcript under ``output_root`` (``YYYY-MM-DD/*.md``)."""
        return self.index_paths(
            iter_transcripts(output_root),
            force=force,
            release_between_files=release_between_files,
        )


def _statements_to_passages(sidecar: StatementSidecar, key: str) -> list[Passage]:
    """Map distilled Statements onto Passage-shaped records for the vec0 store.

    A Statement reuses the Passage schema (same columns) — it differs only in
    being a distilled claim. Its uid carries an ``#s`` infix so it can never
    collide with a real passage uid, and its title is the claim itself, so
    ``search`` results read as the statements they are.
    """
    out: list[Passage] = []
    for i, s in enumerate(sidecar.statements):
        title = s.text if len(s.text) <= _STATEMENT_TITLE_MAX else s.text[: _STATEMENT_TITLE_MAX - 1] + "…"
        out.append(
            Passage(
                uid=f"{key}#s{i}",
                text=s.text,
                start=s.start,
                end=s.end,
                sources=list(s.sources),
                session_id=sidecar.session_id,
                day=int(s.start.strftime("%Y%m%d")),
                path=key,
                title=title,
            )
        )
    return out


class StatementIndexer:
    """Embed a transcript's distilled Statements into their own store.

    Consumes the ``.statements.json`` sidecar (distillation's on-disk contract)
    rather than re-distilling, so the live embed worker and the ``huske index``
    backfill share one path — exactly as :class:`Indexer` consumes the ``.md``.
    Incremental on the sidecar's recorded source hash. The store is a separate
    ``statements.db`` (see ``paths.statements_db_path``); reusing
    :class:`PassageStore` keeps one schema and one set of query primitives.
    """

    def __init__(self, store: PassageStore, embedder: Embedder) -> None:
        self._store = store
        self._embedder = embedder

    def index_file(self, transcript_path: Path, *, force: bool = False) -> int:
        """Embed the Statements for one transcript. Returns statements written (0 if none)."""
        path = transcript_path.resolve()
        key = str(path)
        sidecar = read_sidecar(path)
        if sidecar is None:
            return 0
        digest = sidecar.source_sha256
        if not force and self._store.is_indexed(key, digest):
            return 0
        passages = _statements_to_passages(sidecar, key)
        if not passages:
            # Distilled to nothing (filler-only transcript): clear stale rows, record hash.
            self._store.upsert(key, digest, [], [])
            return 0
        embeddings = self._embedder.embed_passages([p.text for p in passages])
        return self._store.upsert(key, digest, passages, embeddings)


def iter_transcripts(output_root: Path) -> list[Path]:
    """All transcript files under ``output_root``, excluding generated READMEs."""
    if not output_root.exists():
        return []
    return sorted(
        p for p in output_root.glob("*/*.md") if p.name.lower() != "readme.md"
    )
