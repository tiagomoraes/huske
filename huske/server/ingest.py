"""Pure ingest logic: validate, verify, store. No third-party imports.

The write token is the *only* publicly reachable surface of the huske server
(docs/adr/0004), so the request body is treated as hostile:

- ``rel_path`` must be exactly ``YYYY-MM-DD/<name>.md`` — no absolute paths, no
  ``..``, no nested directories, no backslashes — and the resolved target must
  still live under ``output_root`` (defense in depth against traversal).
- the body's ``sha256`` must match the content, or it is rejected.

Storage is idempotent: re-sending identical content is a no-op, matching the
immutable-Transcript model that lets the client key its outbox by hash.
"""

from __future__ import annotations

import hashlib
import os
import re
import tempfile
from pathlib import Path

# YYYY-MM-DD / <filename>.md  — one date dir, one file, nothing else.
_REL_PATH_RE = re.compile(r"^\d{4}-\d{2}-\d{2}/[A-Za-z0-9][A-Za-z0-9._-]*\.md$")


class RelPathError(ValueError):
    """A pushed ``rel_path`` is not a safe ``YYYY-MM-DD/<name>.md`` value."""


class HashMismatchError(ValueError):
    """The body's declared sha256 does not match its content."""


def content_sha256(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def validate_rel_path(rel_path: str) -> str:
    """Return ``rel_path`` if safe, else raise :class:`RelPathError`."""
    if not rel_path or not _REL_PATH_RE.match(rel_path):
        raise RelPathError(f"unsafe or malformed rel_path: {rel_path!r}")
    # Redundant with the regex, but cheap and unmistakable in intent.
    parts = rel_path.split("/")
    if len(parts) != 2 or ".." in parts or "" in parts:
        raise RelPathError(f"unsafe rel_path: {rel_path!r}")
    return rel_path


def verify_hash(content: str, claimed_sha256: str) -> None:
    if content_sha256(content) != claimed_sha256:
        raise HashMismatchError("content does not match declared sha256")


def resolve_target(output_root: Path, rel_path: str) -> Path:
    """Validated absolute target under ``output_root`` (raises on traversal)."""
    validate_rel_path(rel_path)
    root = output_root.resolve()
    target = (root / rel_path).resolve()
    if root != target and root not in target.parents:
        raise RelPathError(f"rel_path escapes output_root: {rel_path!r}")
    return target


def store_transcript(output_root: Path, rel_path: str, content: str) -> tuple[str, Path]:
    """Atomically write ``content`` to ``output_root/rel_path``.

    Returns ``("unchanged", path)`` if an identical file is already present
    (idempotent), else ``("stored", path)``. ``rel_path`` is validated here too,
    so this is safe to call directly.
    """
    target = resolve_target(output_root, rel_path)
    data = content.encode("utf-8")

    if target.exists():
        existing = target.read_bytes()
        if hashlib.sha256(existing).hexdigest() == hashlib.sha256(data).hexdigest():
            return ("unchanged", target)

    target.parent.mkdir(parents=True, exist_ok=True)
    # Write to a temp file in the same directory, then atomically replace — a
    # reader (the indexer / the MCP store) never sees a half-written transcript.
    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), prefix=".ingest-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp_name, target)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    return ("stored", target)
