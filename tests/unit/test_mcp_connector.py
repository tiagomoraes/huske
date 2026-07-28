"""ConnectorApp: discovery endpoints, dual-mode auth, and the browser flow.

Driven by calling the ASGI app directly (scope/receive/send), like
``test_mcp_middleware.py`` and ``test_server_app.py`` — so none of this needs the
``huske[mcp]`` extra or a live socket.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlsplit

import pytest

from huske.mcp.connector import ConnectorApp, protected_resource_metadata_url
from huske.mcp.oauth import (
    READ_SCOPE,
    AuthorizationServer,
    OAuthStore,
    hash_password,
)

RESOURCE = "https://huske.example.com/mcp"
PASSWORD = "correct horse battery staple"
REDIRECT = "https://claude.ai/api/mcp/auth_callback"
STATIC_TOKEN = "loopback-token"


class _Downstream:
    """Stands in for the wrapped MCP app."""

    def __init__(self) -> None:
        self.calls = 0

    async def __call__(self, scope: dict, receive: Any, send: Any) -> None:  # type: ignore[type-arg]
        self.calls += 1
        body = b'{"jsonrpc":"2.0","result":{}}'
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send({"type": "http.response.body", "body": body})


class Response:
    def __init__(self, messages: list[dict]) -> None:  # type: ignore[type-arg]
        start = next(m for m in messages if m["type"] == "http.response.start")
        self.status: int = int(start["status"])
        self.headers: dict[str, str] = {
            k.decode("latin-1").lower(): v.decode("latin-1") for k, v in start["headers"]
        }
        self.body: bytes = b"".join(
            m.get("body", b"") for m in messages if m["type"] == "http.response.body"
        )

    @property
    def text(self) -> str:
        return self.body.decode("utf-8")

    def json(self) -> Any:
        return json.loads(self.text)


def call(
    app: ConnectorApp,
    method: str,
    path: str,
    *,
    query: str = "",
    headers: list[tuple[bytes, bytes]] | None = None,
    body: bytes = b"",
    host: str = "huske.example.com",
) -> Response:
    hdrs = list(headers or [])
    if host:
        hdrs.append((b"host", host.encode("latin-1")))

    async def receive() -> dict:  # type: ignore[type-arg]
        return {"type": "http.request", "body": body, "more_body": False}

    sent: list[dict] = []  # type: ignore[type-arg]

    async def send(message: dict) -> None:  # type: ignore[type-arg]
        sent.append(message)

    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "query_string": query.encode("latin-1"),
        "headers": hdrs,
    }
    asyncio.run(app(scope, receive, send))
    return Response(sent)


def post_form(app: ConnectorApp, path: str, form: dict[str, str]) -> Response:
    return call(
        app,
        "POST",
        path,
        headers=[(b"content-type", b"application/x-www-form-urlencoded")],
        body=urlencode(form).encode("utf-8"),
    )


@pytest.fixture
def downstream() -> _Downstream:
    return _Downstream()


@pytest.fixture
def oauth() -> AuthorizationServer:
    return AuthorizationServer(
        resource=RESOURCE,
        store=OAuthStore.memory(),
        password_hash=hash_password(PASSWORD),
    )


@pytest.fixture
def app(downstream: _Downstream, oauth: AuthorizationServer) -> ConnectorApp:
    return ConnectorApp(
        downstream,
        static_token=STATIC_TOKEN,
        oauth=oauth,
        allowed_hosts=("huske.example.com", "huske.example.com:*"),
    )


# --- the RFC 9728 metadata URL ----------------------------------------------


def test_prm_url_inserts_well_known_before_the_path() -> None:
    assert (
        protected_resource_metadata_url("https://h.example.com/mcp")
        == "https://h.example.com/.well-known/oauth-protected-resource/mcp"
    )


def test_prm_url_without_a_path() -> None:
    assert (
        protected_resource_metadata_url("https://h.example.com")
        == "https://h.example.com/.well-known/oauth-protected-resource"
    )


# --- discovery --------------------------------------------------------------


def test_healthz_is_open(app: ConnectorApp) -> None:
    res = call(app, "GET", "/healthz")
    assert res.status == 200
    assert res.json() == {"status": "ok"}


def test_protected_resource_metadata_is_public(app: ConnectorApp) -> None:
    for path in (
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-protected-resource/mcp",
    ):
        res = call(app, "GET", path)
        assert res.status == 200, path
        assert res.json()["resource"] == RESOURCE
        # Browser-based MCP clients read this cross-origin.
        assert res.headers["access-control-allow-origin"] == "*"


def test_authorization_server_metadata_is_public(app: ConnectorApp) -> None:
    res = call(app, "GET", "/.well-known/oauth-authorization-server")
    assert res.status == 200
    assert res.json()["issuer"] == "https://huske.example.com"


def test_metadata_preflight(app: ConnectorApp) -> None:
    res = call(app, "OPTIONS", "/.well-known/oauth-protected-resource")
    assert res.status == 204
    assert "access-control-allow-methods" in res.headers


# --- the 401 challenge ------------------------------------------------------


def test_unauthenticated_mcp_call_points_at_the_metadata(app: ConnectorApp) -> None:
    res = call(app, "POST", "/mcp")
    assert res.status == 401
    challenge = res.headers["www-authenticate"]
    assert 'resource_metadata="' in challenge
    assert "/.well-known/oauth-protected-resource/mcp" in challenge
    assert f'scope="{READ_SCOPE}"' in challenge


def test_challenge_without_oauth_is_plain_bearer(downstream: _Downstream) -> None:
    plain = ConnectorApp(downstream, static_token=STATIC_TOKEN)
    res = call(plain, "POST", "/mcp", host="127.0.0.1:7641")
    assert res.status == 401
    assert res.headers["www-authenticate"] == "Bearer"


def test_bad_token_is_rejected(app: ConnectorApp, downstream: _Downstream) -> None:
    res = call(app, "POST", "/mcp", headers=[(b"authorization", b"Bearer nope")])
    assert res.status == 401
    assert downstream.calls == 0


# --- dual-mode auth ---------------------------------------------------------


def test_static_token_still_works(app: ConnectorApp, downstream: _Downstream) -> None:
    """Loopback clients (Claude Code, a co-located agent) must be unaffected."""
    res = call(
        app,
        "POST",
        "/mcp",
        headers=[(b"authorization", f"Bearer {STATIC_TOKEN}".encode())],
    )
    assert res.status == 200
    assert downstream.calls == 1


def test_oauth_token_reaches_the_mcp_app(
    app: ConnectorApp, oauth: AuthorizationServer, downstream: _Downstream
) -> None:
    access = _complete_flow(app)
    res = call(app, "POST", "/mcp", headers=[(b"authorization", f"Bearer {access}".encode())])
    assert res.status == 200
    assert downstream.calls == 1


def test_revoked_oauth_token_is_locked_out(
    app: ConnectorApp, oauth: AuthorizationServer, downstream: _Downstream
) -> None:
    access = _complete_flow(app)
    oauth.store.revoke_all_tokens()
    res = call(app, "POST", "/mcp", headers=[(b"authorization", f"Bearer {access}".encode())])
    assert res.status == 401
    assert downstream.calls == 0


# --- host validation --------------------------------------------------------


def test_unexpected_host_is_refused(app: ConnectorApp, downstream: _Downstream) -> None:
    res = call(
        app,
        "POST",
        "/mcp",
        headers=[(b"authorization", f"Bearer {STATIC_TOKEN}".encode())],
        host="attacker.example.com",
    )
    assert res.status == 400
    assert downstream.calls == 0


def test_loopback_host_is_always_allowed(app: ConnectorApp) -> None:
    res = call(
        app,
        "POST",
        "/mcp",
        headers=[(b"authorization", f"Bearer {STATIC_TOKEN}".encode())],
        host="127.0.0.1:7641",
    )
    assert res.status == 200


# --- the browser flow, end to end ------------------------------------------


def _register_via_http(app: ConnectorApp) -> str:
    res = call(
        app,
        "POST",
        "/oauth/register",
        headers=[(b"content-type", b"application/json")],
        body=json.dumps({"redirect_uris": [REDIRECT], "client_name": "Claude"}).encode(),
    )
    assert res.status == 201, res.text
    return str(res.json()["client_id"])


def _pkce() -> tuple[str, str]:
    verifier = "v" * 64
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return verifier, base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def _complete_flow(app: ConnectorApp) -> str:
    """Register → authorize → login → exchange, returning the access token."""
    client_id = _register_via_http(app)
    verifier, challenge = _pkce()
    form = {
        "client_id": client_id,
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "resource": RESOURCE,
        "state": "s1",
        "password": PASSWORD,
    }
    res = post_form(app, "/oauth/authorize", form)
    assert res.status == 302, res.text
    code = parse_qs(urlsplit(res.headers["location"]).query)["code"][0]

    res = post_form(
        app,
        "/oauth/token",
        {
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "resource": RESOURCE,
        },
    )
    assert res.status == 200, res.text
    return str(res.json()["access_token"])


def test_registration_over_http(app: ConnectorApp) -> None:
    assert _register_via_http(app).startswith("huske-")


def test_registration_rejects_non_json(app: ConnectorApp) -> None:
    res = call(app, "POST", "/oauth/register", body=b"not json")
    assert res.status == 400
    assert res.json()["error"] == "invalid_client_metadata"


def test_authorize_get_renders_a_login_form(app: ConnectorApp) -> None:
    client_id = _register_via_http(app)
    _, challenge = _pkce()
    query = urlencode(
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "resource": RESOURCE,
        }
    )
    res = call(app, "GET", "/oauth/authorize", query=query)
    assert res.status == 200
    assert res.headers["content-type"].startswith("text/html")
    assert 'name="password"' in res.text
    assert "Claude" in res.text
    # The prompt must never be framable or cached.
    assert res.headers["x-frame-options"] == "DENY"
    assert res.headers["cache-control"] == "no-store"


def test_authorize_get_with_bad_client_renders_locally(app: ConnectorApp) -> None:
    """An unvalidated redirect_uri must never be followed (open-redirect guard)."""
    res = call(app, "GET", "/oauth/authorize", query="client_id=bogus&redirect_uri=https://evil/cb")
    assert res.status == 400
    assert "location" not in res.headers
    assert "invalid_client" in res.text


def test_full_flow_yields_a_working_token(app: ConnectorApp, downstream: _Downstream) -> None:
    access = _complete_flow(app)
    assert call(
        app, "POST", "/mcp", headers=[(b"authorization", f"Bearer {access}".encode())]
    ).status == 200


def test_wrong_password_re_renders_the_form(app: ConnectorApp) -> None:
    client_id = _register_via_http(app)
    _, challenge = _pkce()
    res = post_form(
        app,
        "/oauth/authorize",
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "resource": RESOURCE,
            "password": "wrong",
        },
    )
    assert res.status == 401
    assert "location" not in res.headers
    assert 'name="password"' in res.text  # retryable, not a dead end


def test_misconfiguration_shows_an_error_page_not_a_retry_form(
    downstream: _Downstream,
) -> None:
    """No passphrase set is a misconfiguration; inviting a retry would be a lie."""
    oauth = AuthorizationServer(
        resource=RESOURCE, store=OAuthStore.memory(), password_hash=None
    )
    app = ConnectorApp(
        downstream, static_token=STATIC_TOKEN, oauth=oauth, allowed_hosts=("huske.example.com",)
    )
    client_id = _register_via_http(app)
    _, challenge = _pkce()
    res = post_form(
        app,
        "/oauth/authorize",
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "resource": RESOURCE,
            "password": "anything",
        },
    )
    assert res.status == 500
    assert 'name="password"' not in res.text
    assert "set-password" in res.text
    assert "location" not in res.headers


def test_token_endpoint_accepts_json_bodies(app: ConnectorApp) -> None:
    """Some MCP clients POST JSON to /token even though OAuth says form-encoded."""
    client_id = _register_via_http(app)
    verifier, challenge = _pkce()
    res = post_form(
        app,
        "/oauth/authorize",
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "resource": RESOURCE,
            "password": PASSWORD,
        },
    )
    code = parse_qs(urlsplit(res.headers["location"]).query)["code"][0]
    res = call(
        app,
        "POST",
        "/oauth/token",
        headers=[(b"content-type", b"application/json")],
        body=json.dumps(
            {"grant_type": "authorization_code", "code": code, "code_verifier": verifier}
        ).encode(),
    )
    assert res.status == 200, res.text
    assert res.json()["token_type"] == "Bearer"


def test_token_errors_are_oauth_shaped(app: ConnectorApp) -> None:
    res = post_form(app, "/oauth/token", {"grant_type": "authorization_code", "code": "x"})
    assert res.status == 400
    assert res.json()["error"] in {"invalid_request", "invalid_grant"}
    assert res.headers["cache-control"] == "no-store"


def test_token_response_is_not_cacheable(app: ConnectorApp) -> None:
    client_id = _register_via_http(app)
    verifier, challenge = _pkce()
    res = post_form(
        app,
        "/oauth/authorize",
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "resource": RESOURCE,
            "password": PASSWORD,
        },
    )
    code = parse_qs(urlsplit(res.headers["location"]).query)["code"][0]
    res = post_form(
        app,
        "/oauth/token",
        {"grant_type": "authorization_code", "code": code, "code_verifier": verifier},
    )
    assert res.headers["cache-control"] == "no-store"


def test_revocation_endpoint(app: ConnectorApp, downstream: _Downstream) -> None:
    access = _complete_flow(app)
    res = post_form(app, "/oauth/revoke", {"token": access})
    assert res.status == 200
    assert call(
        app, "POST", "/mcp", headers=[(b"authorization", f"Bearer {access}".encode())]
    ).status == 401


def test_oauth_routes_are_absent_without_connector_mode(downstream: _Downstream) -> None:
    """Loopback deployments expose no OAuth surface at all."""
    plain = ConnectorApp(downstream, static_token=STATIC_TOKEN)
    res = call(plain, "GET", "/.well-known/oauth-protected-resource", host="127.0.0.1:7641")
    # Falls through to the auth check rather than serving metadata.
    assert res.status == 401


def test_method_not_allowed_on_metadata(app: ConnectorApp) -> None:
    assert call(app, "POST", "/.well-known/oauth-authorization-server").status == 405


# --- build_connector: the refusals that matter -----------------------------


def test_connector_mode_is_off_by_default() -> None:
    from huske.config import RuntimeConfig
    from huske.mcp.server import build_connector

    assert build_connector(RuntimeConfig()) is None


def test_connector_mode_refuses_without_a_passphrase(monkeypatch: pytest.MonkeyPatch) -> None:
    """Publishing a transcript archive with no credential must fail loudly."""
    from huske.config import RuntimeConfig
    from huske.mcp.server import build_connector

    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: None)
    with pytest.raises(ValueError, match="set-password"):
        build_connector(RuntimeConfig(mcp_public_url=RESOURCE))


def test_connector_mode_refuses_plaintext_http(monkeypatch: pytest.MonkeyPatch) -> None:
    from huske.config import RuntimeConfig
    from huske.mcp.server import build_connector

    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: hash_password("x"))
    with pytest.raises(ValueError, match="must be https"):
        build_connector(RuntimeConfig(mcp_public_url="http://huske.example.com/mcp"))


def test_connector_mode_rejects_a_relative_url(monkeypatch: pytest.MonkeyPatch) -> None:
    from huske.config import RuntimeConfig
    from huske.mcp.server import build_connector

    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: hash_password("x"))
    with pytest.raises(ValueError, match="absolute URL"):
        build_connector(RuntimeConfig(mcp_public_url="huske.example.com/mcp"))


def test_connector_mode_builds_with_a_passphrase(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from huske.config import RuntimeConfig
    from huske.mcp.server import build_connector

    monkeypatch.setattr(
        "huske.mcp.oauth.load_password_hash", lambda path=None: hash_password(PASSWORD)
    )
    monkeypatch.setattr("huske.mcp.oauth.default_store_path", lambda: tmp_path / "oauth.db")
    server = build_connector(
        RuntimeConfig(mcp_public_url=RESOURCE + "/", mcp_access_token_ttl_seconds=600)
    )
    assert server is not None
    try:
        assert server.resource == RESOURCE  # trailing slash normalized away
        assert server.access_ttl == 600
    finally:
        server.store.close()


def test_lifespan_passes_through(downstream: _Downstream) -> None:
    app = ConnectorApp(downstream, static_token=STATIC_TOKEN)

    async def run() -> int:
        async def receive() -> dict:  # type: ignore[type-arg]
            return {"type": "lifespan.startup"}

        async def send(message: dict) -> None:  # type: ignore[type-arg]
            return None

        await app({"type": "lifespan"}, receive, send)
        return downstream.calls

    assert asyncio.run(run()) == 1
