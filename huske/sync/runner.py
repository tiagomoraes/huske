"""One-shot Git reconciliation used by ``huske sync`` and the macOS app."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from huske.config import load_config
from huske.sync.client import SyncError, build_publisher, redact_remote


def _print(message: str) -> None:
    print(message, flush=True)


def run_sync(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
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
        publisher = build_publisher(cfg)
        result = publisher.sync()
    except (SyncError, OSError, ValueError) as exc:
        _print(f"[error] {exc}")
        return 1

    if result.changed:
        short = (result.commit or "")[:10]
        _print(f"[huske] published {result.changed} transcript(s) in {short}")
    elif result.pushed:
        _print("[huske] pushed a previously pending commit")
    else:
        _print("[huske] repository is already current")
    return 0
