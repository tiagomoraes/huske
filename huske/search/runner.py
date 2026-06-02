"""`huske index` orchestration: config → embedder → store → backfill."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from huske.config import load_config


def _print(msg: str) -> None:
    print(msg, flush=True)


def _remove_db(db_path: Path) -> None:
    for suffix in ("", "-wal", "-shm"):
        p = db_path.with_name(db_path.name + suffix)
        p.unlink(missing_ok=True)


def run_index(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
    *,
    rebuild: bool = False,
    force: bool = False,
) -> int:
    """Backfill (or rebuild) the passage index. Returns a process exit code."""
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

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

    try:
        embedder = build_embedder(cfg.embedding_model)
    except EmbedderUnavailable as exc:
        _print(f"[error] {exc}")
        return 1

    db_path = index_db_path(cfg)
    if rebuild and db_path.exists():
        _print(f"[huske] rebuilding index at {db_path}")
        _remove_db(db_path)

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

    _print(
        f"[huske] indexing transcripts under {cfg.output_root} "
        f"(model {cfg.embedding_model}, dim {embedder.dim})…"
    )
    try:
        summary = Indexer(store, embedder).backfill(cfg.output_root, force=force)
    finally:
        store.close()

    _print(
        f"\n{summary.files_indexed} indexed, {summary.files_skipped} unchanged, "
        f"{summary.files_failed} failed across {summary.files_seen} transcript(s); "
        f"{summary.passages} passage(s) written."
    )
    for err in summary.errors[:10]:
        _print(f"  [warn] {err.splitlines()[0]}")
    if len(summary.errors) > 10:
        _print(f"  …and {len(summary.errors) - 10} more")
    return 0 if summary.files_failed == 0 else 1
