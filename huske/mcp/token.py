"""Bearer tokens for the MCP daemon and the off-device server.

Stdlib-only (no ``huske[mcp]`` extra needed), so the dependency-free replication
client can read its write token from here too. See
docs/adr/0001-http-only-mcp-daemon.md and 0004-off-device-huske-server.md.
"""

from __future__ import annotations

import os
import secrets
from pathlib import Path


def default_token_path() -> Path:
    """Read token guarding the (loopback) MCP daemon."""
    return Path.home() / ".config" / "huske" / "mcp_token"


def ingest_token_path() -> Path:
    """Server-side write token guarding the ingest endpoint (``huske serve``)."""
    return Path.home() / ".config" / "huske" / "ingest_token"


def sync_token_path() -> Path:
    """Client-side copy of the server's write token (``huske run`` / ``sync``).

    The operator copies the value ``huske serve`` prints into this file on each
    recording Mac that should replicate to the server.
    """
    return Path.home() / ".config" / "huske" / "sync_token"


def load_token(path: Path) -> str | None:
    """Return a token from ``path``, or ``None`` if absent/empty (never creates)."""
    try:
        value = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return None
    return value or None


def load_or_create_token(path: Path | None = None) -> str:
    """Return the daemon's bearer token, creating a 0600 file if absent."""
    target = path or default_token_path()
    if target.exists():
        existing = target.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    token = secrets.token_urlsafe(32)
    target.parent.mkdir(parents=True, exist_ok=True)
    # Write with 0o600 from the start — avoids a race window where the file is
    # world-readable between write_text() and a subsequent chmod().
    fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(token + "\n")
    return token
