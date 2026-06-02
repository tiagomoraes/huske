"""Bearer-token ASGI middleware for the MCP daemon.

Origin/Host (DNS-rebinding) validation is handled by FastMCP's built-in
``transport_security``; this layer adds the static bearer-token check that
guards the loopback endpoint (see docs/adr/0001-http-only-mcp-daemon.md).
Stdlib-only so it's testable without the ``mcp`` extra.
"""

from __future__ import annotations

import hmac
import json
from collections.abc import Awaitable, Callable
from typing import Any

Scope = dict[str, Any]
Message = dict[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]
ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]


class BearerAuthMiddleware:
    """Reject HTTP requests lacking a matching ``Authorization: Bearer`` header."""

    def __init__(self, app: ASGIApp, token: str) -> None:
        self._app = app
        self._expected = f"Bearer {token}"

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            await self._app(scope, receive, send)
            return

        provided = ""
        for name, value in scope.get("headers") or []:
            if name == b"authorization":
                provided = value.decode("latin-1")
                break

        if not hmac.compare_digest(provided, self._expected):
            await _send_401(send)
            return

        await self._app(scope, receive, send)


async def _send_401(send: Send) -> None:
    body = json.dumps({"error": "unauthorized"}).encode("utf-8")
    await send(
        {
            "type": "http.response.start",
            "status": 401,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
                (b"www-authenticate", b"Bearer"),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})
