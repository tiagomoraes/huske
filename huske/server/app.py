"""ASGI app for the ingest endpoint (the only network-exposed surface).

Stdlib-only (no Starlette import) so it is unit-testable by driving
scope/receive/send directly, like ``BearerAuthMiddleware``. Routes:

- ``GET  /healthz`` → 200, unauthenticated (for the reverse proxy's health check)
- ``POST /ingest``  → bearer write-token, validate + store + hand off to indexing

Indexing is *not* done inline here; the app calls ``on_stored(path)`` (which the
runner wires to a background executor) so the event loop never blocks on CPU
embedding, and returns as soon as the transcript is durably on disk.
"""

from __future__ import annotations

import hmac
import json
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from huske.server.ingest import (
    HashMismatchError,
    RelPathError,
    store_transcript,
)
from huske.sync import INGEST_PATH

Scope = dict[str, Any]
Message = dict[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]

_MAX_BODY_BYTES = 32 * 1024 * 1024  # transcripts are small; cap hostile bodies


class IngestApp:
    """The ingest ASGI application. One instance per ``huske serve`` process."""

    def __init__(
        self,
        *,
        output_root: Path,
        write_token: str,
        on_stored: Callable[[Path], None],
        allowed_host: str | None = None,
    ) -> None:
        self._output_root = output_root
        self._expected_auth = f"Bearer {write_token}"
        self._on_stored = on_stored
        self._allowed_host = allowed_host

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "lifespan":
            await self._handle_lifespan(receive, send)
            return
        if scope["type"] != "http":
            return

        method = scope.get("method", "GET")
        path = scope.get("path", "/")

        if method == "GET" and path == "/healthz":
            await _json(send, 200, {"status": "ok"})
            return
        if path != INGEST_PATH:
            await _json(send, 404, {"error": "not found"})
            return
        if method != "POST":
            await _json(send, 405, {"error": "method not allowed"})
            return

        if not self._authorized(scope):
            await _json(send, 401, {"error": "unauthorized"}, extra_headers=[(b"www-authenticate", b"Bearer")])
            return
        if not self._host_ok(scope):
            await _json(send, 400, {"error": "bad host"})
            return

        try:
            body = await _read_body(receive)
        except _BodyTooLarge:
            await _json(send, 413, {"error": "request too large"})
            return

        try:
            payload = json.loads(body.decode("utf-8"))
            rel_path = str(payload["rel_path"])
            sha256 = str(payload["sha256"])
            content = str(payload["content"])
        except (ValueError, KeyError, TypeError):
            await _json(send, 400, {"error": "expected JSON {rel_path, sha256, content}"})
            return

        try:
            from huske.server.ingest import verify_hash

            verify_hash(content, sha256)
            status, stored_path = store_transcript(self._output_root, rel_path, content)
        except RelPathError as exc:
            await _json(send, 400, {"error": str(exc)})
            return
        except HashMismatchError as exc:
            await _json(send, 422, {"error": str(exc)})
            return
        except OSError as exc:
            await _json(send, 500, {"error": f"could not store transcript: {exc}"})
            return

        # Hand off to indexing for both "stored" and "unchanged": if the server
        # had crashed after writing but before indexing, the client re-pushes and
        # this closes the gap (the indexer is idempotent on content hash).
        try:
            self._on_stored(stored_path)
        except Exception:  # indexing is best-effort; never fail the ack on it
            pass

        await _json(send, 200, {"status": status, "rel_path": rel_path})

    # -- helpers -----------------------------------------------------------

    def _authorized(self, scope: Scope) -> bool:
        provided = _header(scope, b"authorization")
        return hmac.compare_digest(provided, self._expected_auth)

    def _host_ok(self, scope: Scope) -> bool:
        if self._allowed_host is None:
            return True
        host = _header(scope, b"host")
        # Strip an optional :port; allow loopback so local checks still pass.
        hostname = host.split(":", 1)[0]
        return hostname in {self._allowed_host, "127.0.0.1", "localhost"}

    async def _handle_lifespan(self, receive: Receive, send: Send) -> None:
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return


class _BodyTooLarge(Exception):
    pass


def _header(scope: Scope, name: bytes) -> str:
    for key, value in scope.get("headers") or []:
        if key == name:
            decoded: str = value.decode("latin-1")
            return decoded
    return ""


async def _read_body(receive: Receive) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        message = await receive()
        if message["type"] != "http.request":
            break
        chunk = message.get("body", b"")
        total += len(chunk)
        if total > _MAX_BODY_BYTES:
            raise _BodyTooLarge
        chunks.append(chunk)
        if not message.get("more_body", False):
            break
    return b"".join(chunks)


async def _json(
    send: Send,
    status: int,
    payload: dict[str, Any],
    *,
    extra_headers: list[tuple[bytes, bytes]] | None = None,
) -> None:
    body = json.dumps(payload).encode("utf-8")
    headers = [
        (b"content-type", b"application/json"),
        (b"content-length", str(len(body)).encode("ascii")),
    ]
    if extra_headers:
        headers.extend(extra_headers)
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})
