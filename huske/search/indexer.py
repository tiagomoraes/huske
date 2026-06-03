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

from huske.search.embedder import Embedder
from huske.search.parser import ParseError, parse_transcript
from huske.search.store import PassageStore
from huske.search.windowing import window


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


def iter_transcripts(output_root: Path) -> list[Path]:
    """All transcript files under ``output_root``, excluding generated READMEs."""
    if not output_root.exists():
        return []
    return sorted(
        p for p in output_root.glob("*/*.md") if p.name.lower() != "readme.md"
    )
