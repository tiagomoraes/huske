"""ASGI wrapper that turns the loopback MCP daemon into a remote connector.

``huske mcp`` normally serves one thing: the MCP endpoint behind a static bearer
token (ADR 0001). That is everything Claude Code and a co-located agent need,
and nothing a phone can use — Claude and ChatGPT only attach a remote MCP server
through the OAuth discovery dance. This wrapper adds the surrounding endpoints
that make the same daemon a first-class connector:

    GET  /healthz                                     → unauthenticated liveness
    GET  /.well-known/oauth-protected-resource[/...]  → RFC 9728 (who authorizes me)
    GET  /.well-known/oauth-authorization-server[/…]  → RFC 8414 (AS endpoints)
    POST /oauth/register                              → RFC 7591 (client signs itself up)
    GET  /oauth/authorize                             → passphrase prompt
    POST /oauth/authorize                             → issue an authorization code
    POST /oauth/token                                 → issue / refresh tokens
    POST /oauth/revoke                                → RFC 7009
    *                                                 → the MCP app, authenticated

Both credentials are accepted on the MCP path, which is what keeps this additive:
the **static token** (loopback clients — Claude Code, hermes — unchanged) and an
**OAuth access token** (connector clients). Without an ``AuthorizationServer``
the wrapper degrades to exactly ``BearerAuthMiddleware`` plus ``/healthz``.

Stdlib-only, so it is unit-testable by driving scope/receive/send directly —
same approach as ``huske/server/app.py``.
"""

from __future__ import annotations

import hmac
import json
from collections.abc import Awaitable, Callable
from typing import Any
from urllib.parse import parse_qs

from huske.mcp.oauth import READ_SCOPE, AuthorizationServer, OAuthError, escape_html

Scope = dict[str, Any]
Message = dict[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]
ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]

_MAX_BODY_BYTES = 256 * 1024  # OAuth bodies are tiny; cap hostile ones

_WELL_KNOWN_PRM = "/.well-known/oauth-protected-resource"
_WELL_KNOWN_AS = "/.well-known/oauth-authorization-server"


def protected_resource_metadata_url(resource: str) -> str:
    """The RFC 9728 metadata URL for ``resource``.

    RFC 9728 inserts the well-known segment *before* the resource's path, so
    ``https://h/mcp`` is described at
    ``https://h/.well-known/oauth-protected-resource/mcp``. Clients build this
    themselves; we advertise the identical string so the two always agree.
    """
    from huske.mcp.oauth import resource_origin

    origin = resource_origin(resource)
    path = resource[len(origin) :].strip("/")
    return f"{origin}{_WELL_KNOWN_PRM}" + (f"/{path}" if path else "")


class ConnectorApp:
    """Front the MCP app with OAuth discovery, token issuance, and auth."""

    def __init__(
        self,
        app: ASGIApp,
        *,
        static_token: str,
        oauth: AuthorizationServer | None = None,
        allowed_hosts: tuple[str, ...] = (),
    ) -> None:
        self._app = app
        self._expected_static = f"Bearer {static_token}"
        self._oauth = oauth
        self._allowed_hosts = {h.lower() for h in allowed_hosts} | {
            "127.0.0.1",
            "localhost",
            "[::1]",
        }
        self._prm_url = (
            protected_resource_metadata_url(oauth.resource) if oauth is not None else ""
        )

    # -- ASGI --------------------------------------------------------------

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http":
            # Lifespan and websocket scopes belong to the wrapped app.
            await self._app(scope, receive, send)
            return

        path: str = scope.get("path", "/")
        method: str = scope.get("method", "GET")

        if method == "GET" and path == "/healthz":
            await _json(send, 200, {"status": "ok"})
            return

        if not self._host_ok(scope):
            await _json(send, 400, {"error": "bad host"})
            return

        if self._oauth is not None:
            handled = await self._handle_oauth(self._oauth, path, method, scope, receive, send)
            if handled:
                return

        if not self._authorized(scope):
            await self._challenge(send)
            return

        await self._app(scope, receive, send)

    # -- public (unauthenticated) OAuth surface ----------------------------

    async def _handle_oauth(
        self,
        oauth: AuthorizationServer,
        path: str,
        method: str,
        scope: Scope,
        receive: Receive,
        send: Send,
    ) -> bool:
        """Serve a discovery/OAuth route. Returns False if ``path`` isn't one."""
        # Browser-based MCP clients preflight the metadata documents, and both
        # are public by definition — so answer CORS on them, and only them.
        if path.startswith((_WELL_KNOWN_PRM, _WELL_KNOWN_AS)):
            if method == "OPTIONS":
                await _json(send, 204, {}, cors=True, empty=True)
                return True
            if method != "GET":
                await _json(send, 405, {"error": "method not allowed"})
                return True
            body = (
                oauth.protected_resource_metadata()
                if path.startswith(_WELL_KNOWN_PRM)
                else oauth.metadata()
            )
            await _json(send, 200, body, cors=True)
            return True

        if path == "/oauth/register":
            if method == "OPTIONS":
                await _json(send, 204, {}, cors=True, empty=True)
                return True
            if method != "POST":
                await _json(send, 405, {"error": "method not allowed"})
                return True
            await self._register(oauth, receive, send)
            return True

        if path == "/oauth/authorize":
            if method == "GET":
                await self._authorize_get(oauth, scope, send)
            elif method == "POST":
                await self._authorize_post(oauth, receive, send)
            else:
                await _json(send, 405, {"error": "method not allowed"})
            return True

        if path == "/oauth/token":
            if method == "OPTIONS":
                await _json(send, 204, {}, cors=True, empty=True)
                return True
            if method != "POST":
                await _json(send, 405, {"error": "method not allowed"})
                return True
            await self._token(oauth, receive, send)
            return True

        if path == "/oauth/revoke":
            if method != "POST":
                await _json(send, 405, {"error": "method not allowed"})
                return True
            form = await _read_form(receive)
            oauth.revoke(form)
            await _json(send, 200, {"status": "ok"}, cors=True)
            return True

        return False

    async def _register(
        self, oauth: AuthorizationServer, receive: Receive, send: Send
    ) -> None:
        try:
            raw = await _read_body(receive)
            payload = json.loads(raw.decode("utf-8")) if raw else {}
            if not isinstance(payload, dict):
                raise ValueError("expected a JSON object")
        except (_BodyTooLarge, ValueError, UnicodeDecodeError):
            await _json(
                send,
                400,
                {"error": "invalid_client_metadata", "error_description": "expected a JSON object"},
                cors=True,
            )
            return
        try:
            registered = oauth.register(payload)
        except OAuthError as exc:
            await _json(send, exc.status, exc.to_dict(), cors=True)
            return
        await _json(send, 201, registered, cors=True)

    async def _authorize_get(
        self, oauth: AuthorizationServer, scope: Scope, send: Send
    ) -> None:
        params = _query_params(scope)
        try:
            request = oauth.parse_authorization_request(params)
        except OAuthError as exc:
            await _error_page(send, exc)
            return
        locked = oauth.login_locked_for()
        note = (
            f"Locked after repeated failed attempts — try again in {int(locked) + 1}s."
            if locked > 0
            else ""
        )
        from huske.mcp.oauth import render_login_page

        await _html(send, 200, render_login_page(request, note=note))

    async def _authorize_post(
        self, oauth: AuthorizationServer, receive: Receive, send: Send
    ) -> None:
        form = await _read_form(receive)
        try:
            request = oauth.parse_authorization_request(form)
        except OAuthError as exc:
            await _error_page(send, exc)
            return

        from huske.mcp.oauth import render_login_page

        try:
            location = oauth.complete_authorization(request, form.get("password", ""))
        except OAuthError as exc:
            if exc.status >= 500:
                # Misconfiguration (e.g. no passphrase set), not a bad guess —
                # re-rendering the form would invite the user to retry forever.
                await _error_page(send, exc)
                return
            # Otherwise re-render the form rather than redirecting: the user is a
            # human in a browser, and an access_denied redirect would leave them
            # on the client's error screen with no way to try again.
            await _html(
                send,
                exc.status if exc.status in (401, 429) else 401,
                render_login_page(request, error=exc.description or exc.error),
            )
            return
        await _redirect(send, location)

    async def _token(self, oauth: AuthorizationServer, receive: Receive, send: Send) -> None:
        form = await _read_form(receive)
        try:
            payload = oauth.token(form)
        except OAuthError as exc:
            await _json(send, exc.status, exc.to_dict(), cors=True, no_store=True)
            return
        await _json(send, 200, payload, cors=True, no_store=True)

    # -- auth --------------------------------------------------------------

    def _authorized(self, scope: Scope) -> bool:
        provided = _header(scope, b"authorization")
        if hmac.compare_digest(provided, self._expected_static):
            return True
        if self._oauth is None or not provided.startswith("Bearer "):
            return False
        return self._oauth.validate_access_token(provided[len("Bearer ") :].strip()) is not None

    async def _challenge(self, send: Send) -> None:
        """401 with the RFC 9728 pointer a client follows to start the OAuth flow."""
        if self._prm_url:
            value = f'Bearer resource_metadata="{self._prm_url}", scope="{READ_SCOPE}"'
        else:
            value = "Bearer"
        await _json(
            send,
            401,
            {"error": "unauthorized"},
            extra_headers=[(b"www-authenticate", value.encode("latin-1"))],
        )

    def _host_ok(self, scope: Scope) -> bool:
        """Reject a Host we do not serve (DNS-rebinding defense, as on ingest)."""
        if not self._allowed_hosts:
            return True
        host = _header(scope, b"host").lower()
        if not host:
            return True  # HTTP/1.0 or a direct ASGI call; the socket bind governs
        hostname = host.rsplit(":", 1)[0] if not host.endswith("]") else host
        return hostname in self._allowed_hosts or host in self._allowed_hosts


# --- ASGI helpers -----------------------------------------------------------


class _BodyTooLarge(Exception):
    pass


def _header(scope: Scope, name: bytes) -> str:
    for key, value in scope.get("headers") or []:
        if key == name:
            decoded: str = value.decode("latin-1")
            return decoded
    return ""


def _query_params(scope: Scope) -> dict[str, str]:
    raw = scope.get("query_string") or b""
    if isinstance(raw, str):  # pragma: no cover - some test drivers pass str
        raw = raw.encode("latin-1")
    return {k: v[0] for k, v in parse_qs(raw.decode("latin-1"), keep_blank_values=True).items()}


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


async def _read_form(receive: Receive) -> dict[str, str]:
    """Parse a request body as form-encoded, falling back to JSON.

    OAuth specifies ``application/x-www-form-urlencoded`` on the token endpoint,
    but real MCP clients have shipped JSON there; accepting both costs three
    lines and avoids an interop dead end.
    """
    try:
        raw = await _read_body(receive)
    except _BodyTooLarge:
        return {}
    if not raw:
        return {}
    text = raw.decode("utf-8", errors="replace").lstrip()
    if text.startswith("{"):
        try:
            loaded = json.loads(text)
        except ValueError:
            return {}
        if isinstance(loaded, dict):
            return {str(k): "" if v is None else str(v) for k, v in loaded.items()}
        return {}
    return {k: v[0] for k, v in parse_qs(text, keep_blank_values=True).items()}


_CORS_HEADERS = [
    (b"access-control-allow-origin", b"*"),
    (b"access-control-allow-methods", b"GET, POST, OPTIONS"),
    (b"access-control-allow-headers", b"authorization, content-type, mcp-protocol-version"),
    (b"access-control-max-age", b"86400"),
]


async def _json(
    send: Send,
    status: int,
    payload: dict[str, Any],
    *,
    extra_headers: list[tuple[bytes, bytes]] | None = None,
    cors: bool = False,
    no_store: bool = False,
    empty: bool = False,
) -> None:
    body = b"" if empty else json.dumps(payload).encode("utf-8")
    headers = [(b"content-length", str(len(body)).encode("ascii"))]
    if not empty:
        headers.append((b"content-type", b"application/json"))
    if cors:
        headers.extend(_CORS_HEADERS)
    if no_store:
        headers.append((b"cache-control", b"no-store"))
    if extra_headers:
        headers.extend(extra_headers)
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


async def _html(send: Send, status: int, markup: str) -> None:
    body = markup.encode("utf-8")
    await send(
        {
            "type": "http.response.start",
            "status": status,
            "headers": [
                (b"content-type", b"text/html; charset=utf-8"),
                (b"content-length", str(len(body)).encode("ascii")),
                (b"cache-control", b"no-store"),
                # The login page must never be framed by another origin.
                (b"x-frame-options", b"DENY"),
                (
                    b"content-security-policy",
                    b"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
                ),
                (b"referrer-policy", b"no-referrer"),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})


async def _redirect(send: Send, location: str) -> None:
    await send(
        {
            "type": "http.response.start",
            "status": 302,
            "headers": [
                (b"location", location.encode("latin-1")),
                (b"content-length", b"0"),
                (b"cache-control", b"no-store"),
            ],
        }
    )
    await send({"type": "http.response.body", "body": b""})


async def _error_page(send: Send, exc: OAuthError) -> None:
    """Render an authorization error locally instead of redirecting.

    A redirect here would need a ``redirect_uri`` we have not validated — the
    open-redirect primitive behind confused-deputy attacks — so the user sees the
    error on huske's own origin.
    """
    detail = escape_html(exc.description or exc.error)
    markup = (
        "<!doctype html><html lang=en><head><meta charset=utf-8/>"
        '<meta name="viewport" content="width=device-width,initial-scale=1"/>'
        "<title>huske — cannot connect</title>"
        "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;"
        "background:#0b0b0c;color:#ededef;font:15px/1.6 ui-sans-serif,-apple-system,sans-serif;"
        "padding:24px}div{max-width:420px;background:#131315;border:1px solid #26262a;"
        "border-radius:14px;padding:28px}code{font-family:ui-monospace,monospace;color:#ff9f9f}"
        "</style></head><body><div>"
        "<p><strong>huske could not start that authorization.</strong></p>"
        f"<p><code>{escape_html(exc.error)}</code> — {detail}</p>"
        "<p style='color:#8a8a92;font-size:13px'>Remove and re-add the connector to retry.</p>"
        "</div></body></html>"
    )
    await _html(send, exc.status if exc.status >= 400 else 400, markup)
