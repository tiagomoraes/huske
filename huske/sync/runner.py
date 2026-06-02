"""``huske sync``: push every not-yet-acknowledged transcript, then exit.

A synchronous backfill (no background thread) — the manual counterpart to the
live replication ``huske run`` performs. Useful for the first sync of an
existing corpus, or to flush after the Mac was offline.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from huske.config import load_config
from huske.mcp.token import load_token, sync_token_path
from huske.paths import outbox_db_path
from huske.sync.client import IngestClient, SyncError, sha256_hex
from huske.sync.outbox import Outbox
from huske.sync.worker import iter_transcripts


def _print(msg: str) -> None:
    print(msg, flush=True)


def run_sync(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
) -> int:
    """Backfill the huske server from the local transcript corpus. Exit code."""
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    if not cfg.sync_endpoint:
        _print(
            "[error] no sync_endpoint configured. Set it in ~/.config/huske/config.toml "
            "to your huske server URL (e.g. https://huske.example.com)."
        )
        return 2

    token = load_token(sync_token_path())
    if not token:
        _print(
            f"[error] no write token at {sync_token_path()}. Copy the token "
            "`huske serve` printed on your server into that file (chmod 600)."
        )
        return 2

    client = IngestClient(cfg.sync_endpoint, token, verify_tls=cfg.sync_verify_tls)
    outbox = Outbox(outbox_db_path(cfg))
    sent = skipped = failed = 0
    try:
        transcripts = iter_transcripts(cfg.output_root)
        _print(
            f"[huske] syncing {len(transcripts)} transcript(s) under {cfg.output_root} "
            f"→ {cfg.sync_endpoint}"
        )
        for path in transcripts:
            rel = _rel_path(path, cfg.output_root)
            if rel is None:
                continue
            content = path.read_text(encoding="utf-8")
            digest = sha256_hex(content)
            if outbox.is_sent(rel, digest):
                skipped += 1
                continue
            try:
                result = client.push(rel, content, digest)
            except SyncError as exc:
                failed += 1
                outbox.record_failure(rel, str(exc))
                _print(f"  [fail] {rel}: {exc}")
                continue
            outbox.mark_sent(rel, digest)
            sent += 1
            _print(f"  [{result.status:>9}] {rel}")
    finally:
        outbox.close()

    _print(f"\n{sent} sent, {skipped} already current, {failed} failed.")
    return 0 if failed == 0 else 1


def _rel_path(path: Path, output_root: Path) -> str | None:
    try:
        return path.resolve().relative_to(output_root.resolve()).as_posix()
    except ValueError:
        return None
