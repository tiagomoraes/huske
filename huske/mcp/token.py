"""Bearer token for the MCP daemon: load from disk, generate on first use."""

from __future__ import annotations

import secrets
from pathlib import Path


def default_token_path() -> Path:
    return Path.home() / ".config" / "huske" / "mcp_token"


def load_or_create_token(path: Path | None = None) -> str:
    """Return the daemon's bearer token, creating a 0600 file if absent."""
    target = path or default_token_path()
    if target.exists():
        existing = target.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    token = secrets.token_urlsafe(32)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(token + "\n", encoding="utf-8")
    try:
        target.chmod(0o600)
    except OSError:  # pragma: no cover - platform dependent
        pass
    return token
