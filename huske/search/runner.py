"""`huske index` orchestration: config → embedder → store → backfill."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from huske.config import load_config

# Low-impact backfill tuning. `huske index` runs gentle by default (see
# RuntimeConfig.index_low_impact / the `--fast` flag): a one-shot backfill must
# not be allowed to pin the GPU or swap-storm the Mac when there's no rush.
_GENTLE_NICE = 10  # niceness increment — yield CPU to interactive work
_GENTLE_BATCH_CAP = 8  # smaller forward passes → lower peak memory
_GENTLE_CACHE_LIMIT_MB = 256  # bound MLX's reusable buffer pool


def _print(msg: str) -> None:
    print(msg, flush=True)


def _lower_process_priority(nice_increment: int = _GENTLE_NICE) -> None:
    """Best-effort: deprioritize this process so the backfill yields CPU to the
    user's foreground work. Process-global and not raised back within the run,
    which is fine for a one-shot command. Kept as a seam so tests can neutralize
    it (the unit suite drives `huske index` in-process).
    """
    try:
        os.nice(nice_increment)
    except (OSError, AttributeError):  # pragma: no cover - platform dependent
        pass


def _remove_db(db_path: Path) -> None:
    for suffix in ("", "-wal", "-shm"):
        p = db_path.with_name(db_path.name + suffix)
        p.unlink(missing_ok=True)


def _backfill_statements(
    cfg: Any, embedder: Any, *, force: bool, gentle: bool
) -> tuple[int, int]:
    """Embed any distilled-statement sidecars into the statement store.

    Makes ``huske distill`` (write sidecars) + ``huske index`` (embed them) a
    complete offline two-stage backfill, sharing the one embedder already loaded.
    Returns ``(transcripts_with_statements, statements_written)``; a no-op (0, 0)
    when no sidecars exist yet.
    """
    from huske.paths import statements_db_path, statements_sidecar_path
    from huske.search.indexer import StatementIndexer, iter_transcripts
    from huske.search.store import PassageStore

    transcripts = iter_transcripts(cfg.output_root)
    if not any(statements_sidecar_path(t).exists() for t in transcripts):
        return (0, 0)

    store = PassageStore.open(
        statements_db_path(cfg),
        embedding_model=cfg.embedding_model,
        dim=embedder.dim,
        create=True,
    )
    indexer = StatementIndexer(store, embedder)
    release = getattr(embedder, "release", None)
    files = total = 0
    try:
        for t in transcripts:
            try:
                n = indexer.index_file(t, force=force)
            except Exception:
                continue
            finally:
                if gentle and callable(release):
                    try:
                        release()
                    except Exception:
                        pass
            if n > 0:
                files += 1
                total += n
    finally:
        store.close()
    return (files, total)


def run_index(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
    *,
    rebuild: bool = False,
    force: bool = False,
    low_impact: bool | None = None,
) -> int:
    """Backfill (or rebuild) the passage index. Returns a process exit code.

    The backfill runs in low-impact mode (gentle CPU/RAM footprint) unless
    ``low_impact`` is ``False``. ``low_impact=None`` defers to the config's
    ``index_low_impact`` (default ``True``).
    """
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    gentle = cfg.index_low_impact if low_impact is None else low_impact

    try:
        from huske.paths import index_db_path
        from huske.search.embedder import EmbedderUnavailable, build_embedder
        from huske.search.indexer import Indexer
        from huske.search.store import ModelMismatchError, PassageStore, StoreUnavailable
    except ImportError as exc:  # pragma: no cover - extra not installed
        _print(
            f"[error] local search needs the extra: pip install 'huske[mcp]' ({exc})"
        )
        return 1

    if gentle:
        _lower_process_priority()
    batch_size = min(cfg.embed_batch_size, _GENTLE_BATCH_CAP) if gentle else cfg.embed_batch_size
    cache_limit_mb = _GENTLE_CACHE_LIMIT_MB if gentle else None

    try:
        embedder = build_embedder(
            cfg.embedding_model,
            batch_size=batch_size,
            cache_limit_mb=cache_limit_mb,
            memory_limit_mb=cfg.index_memory_limit_mb,
        )
    except EmbedderUnavailable as exc:
        _print(f"[error] {exc}")
        return 1

    db_path = index_db_path(cfg)
    if rebuild and db_path.exists():
        _print(f"[huske] rebuilding index at {db_path}")
        _remove_db(db_path)
    if rebuild:
        # Statements share the embedding space, so a model change invalidates
        # them too — clear the statement store on rebuild or it would refuse to
        # open with the new model (ModelMismatchError). Re-embedded below from
        # the sidecars, which are independent of the embedding model.
        from huske.paths import statements_db_path

        _remove_db(statements_db_path(cfg))

    try:
        store = PassageStore.open(
            db_path,
            embedding_model=cfg.embedding_model,
            dim=embedder.dim,
            create=True,
        )
    except ModelMismatchError as exc:
        _print(f"[error] {exc}")
        return 1
    except StoreUnavailable as exc:
        _print(f"[error] {exc}")
        return 1

    if gentle:
        _print(
            f"[huske] low-impact mode: nice +{_GENTLE_NICE}, embed batch {batch_size}, "
            f"MLX cache <= {_GENTLE_CACHE_LIMIT_MB} MB, releasing buffers between "
            "files. Pass --fast to run the backfill at full speed."
        )
    _print(
        f"[huske] indexing transcripts under {cfg.output_root} "
        f"(model {cfg.embedding_model}, dim {embedder.dim})…"
    )
    try:
        summary = Indexer(store, embedder).backfill(
            cfg.output_root, force=force, release_between_files=gentle
        )
    finally:
        store.close()

    try:
        stmt_files, stmt_count = _backfill_statements(cfg, embedder, force=force, gentle=gentle)
    except Exception as exc:  # statement embedding must never fail the passage index
        _print(f"  [warn] statement index skipped: {exc}")
        stmt_files = stmt_count = 0

    _print(
        f"\n{summary.files_indexed} indexed, {summary.files_skipped} unchanged, "
        f"{summary.files_failed} failed across {summary.files_seen} transcript(s); "
        f"{summary.passages} passage(s) written."
    )
    if stmt_files or stmt_count:
        _print(
            f"{stmt_count} statement(s) embedded from {stmt_files} distilled transcript(s)."
        )
    for err in summary.errors[:10]:
        _print(f"  [warn] {err.splitlines()[0]}")
    if len(summary.errors) > 10:
        _print(f"  …and {len(summary.errors) - 10} more")
    return 0 if summary.files_failed == 0 else 1
