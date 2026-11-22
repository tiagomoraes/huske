"""One-shot Git reconciliation used by ``huske sync`` and the macOS app."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from huske.config import load_config
from huske.sync.client import SyncError, SyncResult, build_publisher, redact_remote

# How many paths to list before summarising the rest.
_LIST_LIMIT = 5


def _print(message: str) -> None:
    print(message, flush=True)


def _print_paths(paths: tuple[str, ...]) -> None:
    for path in paths[:_LIST_LIMIT]:
        _print(f"  {path}")
    if len(paths) > _LIST_LIMIT:
        _print(f"  … and {len(paths) - _LIST_LIMIT} more")


def run_sync(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
    *,
    republish: tuple[str, ...] = (),
) -> int:
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    if not cfg.sync_remote:
        _print(
            "[error] no sync_remote configured. Create a private GitHub repository "
            "and paste its SSH URL in Huske → Cloud sync."
        )
        return 2

    _print(
        f"[huske] syncing transcripts under {cfg.output_root} → "
        f"{redact_remote(cfg.sync_remote)} ({cfg.sync_branch})"
    )
    try:
        publisher = build_publisher(cfg, republish=republish)
        result = publisher.sync()
    except (SyncError, OSError, ValueError) as exc:
        _print(f"[error] {exc}")
        return 1

    return _report(result)


def _report(result: SyncResult) -> int:
    for note in result.notes:
        _print(f"[huske] {note}")

    if result.changed:
        short = (result.commit or "")[:10]
        added = result.changed - result.updated
        parts = []
        if added:
            parts.append(f"{added} new")
        if result.updated:
            parts.append(f"{result.updated} updated")
        _print(f"[huske] published {' and '.join(parts)} transcript(s) in {short}")
    elif result.total == 0:
        _print("[huske] connected; no transcripts to publish yet")
    elif result.pushed:
        _print("[huske] pushed pending changes")
    else:
        _print(f"[huske] repository is already current ({result.total} transcript(s))")

    if result.removed_remotely:
        _print(
            f"[huske] {len(result.removed_remotely)} transcript(s) were deleted from "
            "the repository and stay unpublished (they remain on this Mac):"
        )
        _print_paths(result.removed_remotely)
        _print("[huske] To publish one again: huske sync --republish <path>")

    if result.conflicts:
        _print(
            f"[warn] {len(result.conflicts)} transcript(s) were changed in the "
            "repository, so Huske left them as is:"
        )
        _print_paths(result.conflicts)
        _print(
            "[warn] Everything else was published. To replace a repository copy "
            "with this Mac's version: huske sync --republish <path>"
        )
        return 1
    return 0
