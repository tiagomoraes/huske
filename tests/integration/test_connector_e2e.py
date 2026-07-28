"""The whole connector flow against a real server: uvicorn + FastMCP + OAuth.

The unit tests drive ``ConnectorApp`` directly, which proves the routing and the
OAuth logic but not the composition — that the discovery and ``/oauth/*`` paths
don't collide with the routes FastMCP mounts, that the SDK's DNS-rebinding guard
lets a connector request through, and that an OAuth-issued token actually reaches
a tool. That only shows up over a socket, so this test starts the real
``huske.mcp.server.run`` and speaks HTTP to it with stdlib ``urllib``.

Needs the ``huske[mcp]`` extra, so it skips where CI installs only ``.[dev]``.
Run it locally with::

    pytest tests/integration/test_connector_e2e.py
"""

from __future__ import annotations

import base64
import hashlib
import json
import socket
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlsplit

import pytest

pytest.importorskip("sqlite_vec")
pytest.importorskip("mcp")
pytest.importorskip("uvicorn")

from huske.config import RuntimeConfig
from huske.search.embedder import HashingEmbedder
from huske.search.models import Passage
from huske.search.store import PassageStore

PASSWORD = "a-very-long-test-passphrase"
REDIRECT = "http://127.0.0.1:9999/cb"
EMB = HashingEmbedder(dim=64)
DAY = datetime(2026, 7, 27, 9, 30).astimezone()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep the 302 instead of following it.

    A real MCP client hands the redirect to its own callback listener; urllib
    would chase it to a port nothing is bound to.
    """

    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
    return port


class Client:
    """Minimal HTTP client bound to the server under test."""

    def __init__(self, base: str) -> None:
        self.base = base
        self._opener = urllib.request.build_opener(_NoRedirect)

    def get(self, path: str, **headers: str) -> tuple[int, bytes, dict[str, str]]:
        req = urllib.request.Request(self.base + path, headers=headers)
        return self._send(req)

    def post(
        self, path: str, data: dict[str, Any], *, json_body: bool = False, **headers: str
    ) -> tuple[int, bytes, dict[str, str]]:
        body = json.dumps(data).encode() if json_body else urlencode(data).encode()
        hdrs = {
            "content-type": "application/json"
            if json_body
            else "application/x-www-form-urlencoded",
            **headers,
        }
        req = urllib.request.Request(self.base + path, data=body, headers=hdrs, method="POST")
        return self._send(req)

    def rpc(self, method: str, token: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        status, body, _ = self.post(
            "/mcp",
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}},
            json_body=True,
            authorization=f"Bearer {token}",
            accept="application/json, text/event-stream",
        )
        assert status == 200, body
        parsed: dict[str, Any] = json.loads(body)
        return parsed

    def _send(self, req: urllib.request.Request) -> tuple[int, bytes, dict[str, str]]:
        try:
            with self._opener.open(req, timeout=10) as r:
                return int(r.status), r.read(), {k.lower(): v for k, v in r.headers.items()}
        except urllib.error.HTTPError as exc:
            return int(exc.code), exc.read(), {k.lower(): v for k, v in exc.headers.items()}


@pytest.fixture(scope="module")
def server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Client]:
    """Start the production ``run()`` on a free port with an isolated HOME."""
    home = tmp_path_factory.mktemp("home")
    port = _free_port()
    base = f"http://127.0.0.1:{port}"

    monkeypatch = pytest.MonkeyPatch()
    # Every credential path funnels through Path.home(), so one hook isolates
    # mcp_token, mcp_password, and oauth.db from the developer's real ~/.
    monkeypatch.setattr(Path, "home", staticmethod(lambda: home))

    from huske.mcp.oauth import save_password_hash

    save_password_hash(PASSWORD)

    cfg = RuntimeConfig(
        index_root=home / "index",
        output_root=home / "transcripts",
        embedding_model="hashing:64",
        mcp_port=port,
        # 127.0.0.1 is the one non-https public url connector mode accepts, so
        # this can exercise the flow without standing up TLS.
        mcp_public_url=f"{base}/mcp",
        log_level="WARNING",
    )

    from huske.paths import index_db_path

    store = PassageStore.open(index_db_path(cfg), embedding_model="hashing:64", dim=64)
    passages = [
        Passage(
            uid="/t/a#0",
            text="we agreed to ship on friday",
            start=DAY,
            end=DAY + timedelta(minutes=2),
            sources=["mic"],
            session_id="s1",
            day=20260727,
            path="/t/a",
            title="2026-07-27 09:30 · mic",
        )
    ]
    store.upsert("/t/a", "h", passages, EMB.embed_passages([p.text for p in passages]))
    store.close()

    from huske.mcp.server import run as run_mcp

    # A daemon thread: uvicorn.run() owns the signal handlers and cannot be
    # stopped from another thread, and the port is unique per run.
    threading.Thread(target=run_mcp, args=(cfg,), daemon=True).start()

    client = Client(base)
    for _ in range(200):
        try:
            client.get("/healthz")
            break
        except OSError:
            time.sleep(0.05)
    else:  # pragma: no cover - the server failed to bind
        monkeypatch.undo()
        pytest.fail("connector server never came up")

    yield client
    monkeypatch.undo()


def _pkce() -> tuple[str, str]:
    verifier = "z" * 64
    digest = hashlib.sha256(verifier.encode()).digest()
    return verifier, base64.urlsafe_b64encode(digest).decode().rstrip("=")


def _register(server: Client) -> str:
    status, body, _ = server.post(
        "/oauth/register",
        {"redirect_uris": [REDIRECT], "client_name": "E2E"},
        json_body=True,
    )
    assert status == 201, body
    return str(json.loads(body)["client_id"])


def _authorize_params(client_id: str, challenge: str, base: str) -> dict[str, str]:
    return {
        "client_id": client_id,
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "resource": f"{base}/mcp",
        "state": "st",
    }


def _issue(server: Client) -> dict[str, Any]:
    """Register → authorize → sign in → exchange, returning the token response."""
    client_id = _register(server)
    verifier, challenge = _pkce()
    params = _authorize_params(client_id, challenge, server.base)
    status, _, headers = server.post("/oauth/authorize", {**params, "password": PASSWORD})
    assert status == 302
    code = parse_qs(urlsplit(headers["location"]).query)["code"][0]
    status, body, _ = server.post(
        "/oauth/token",
        {
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "resource": f"{server.base}/mcp",
        },
    )
    assert status == 200, body
    tokens: dict[str, Any] = json.loads(body)
    return tokens


# --- discovery --------------------------------------------------------------


def test_healthz_needs_no_credential(server: Client) -> None:
    status, body, _ = server.get("/healthz")
    assert status == 200
    assert json.loads(body) == {"status": "ok"}


def test_protected_resource_metadata_is_served(server: Client) -> None:
    status, body, _ = server.get("/.well-known/oauth-protected-resource/mcp")
    assert status == 200
    assert json.loads(body)["resource"] == f"{server.base}/mcp"


def test_authorization_server_metadata_is_served(server: Client) -> None:
    status, body, _ = server.get("/.well-known/oauth-authorization-server")
    assert status == 200
    meta = json.loads(body)
    assert meta["code_challenge_methods_supported"] == ["S256"]
    assert meta["registration_endpoint"].endswith("/oauth/register")


def test_unauthenticated_call_challenges_with_the_metadata_url(server: Client) -> None:
    """This header is how a client finds its way into the OAuth flow at all."""
    status, _, headers = server.post("/mcp", {}, json_body=True)
    assert status == 401
    assert "oauth-protected-resource" in headers["www-authenticate"]


# --- the flow ---------------------------------------------------------------


def test_dynamic_client_registration(server: Client) -> None:
    assert _register(server).startswith("huske-")


def test_authorize_renders_a_login_form(server: Client) -> None:
    client_id = _register(server)
    _, challenge = _pkce()
    query = urlencode(_authorize_params(client_id, challenge, server.base))
    status, body, headers = server.get(f"/oauth/authorize?{query}")
    assert status == 200
    assert headers["content-type"].startswith("text/html")
    assert b'name="password"' in body


def test_wrong_passphrase_does_not_redirect(server: Client) -> None:
    client_id = _register(server)
    _, challenge = _pkce()
    params = _authorize_params(client_id, challenge, server.base)
    status, body, headers = server.post("/oauth/authorize", {**params, "password": "wrong"})
    assert status == 401
    assert "location" not in headers
    assert b'name="password"' in body  # retryable, not a dead end


def test_authorization_redirect_carries_code_and_iss(server: Client) -> None:
    client_id = _register(server)
    _, challenge = _pkce()
    params = _authorize_params(client_id, challenge, server.base)
    status, _, headers = server.post("/oauth/authorize", {**params, "password": PASSWORD})
    assert status == 302
    query = parse_qs(urlsplit(headers["location"]).query)
    assert query["state"] == ["st"]
    assert query["iss"] == [server.base]
    assert query["code"]


def test_token_exchange_and_code_replay(server: Client) -> None:
    client_id = _register(server)
    verifier, challenge = _pkce()
    params = _authorize_params(client_id, challenge, server.base)
    _, _, headers = server.post("/oauth/authorize", {**params, "password": PASSWORD})
    code = parse_qs(urlsplit(headers["location"]).query)["code"][0]

    form = {"grant_type": "authorization_code", "code": code, "code_verifier": verifier}
    status, body, _ = server.post("/oauth/token", dict(form))
    assert status == 200
    assert json.loads(body)["token_type"] == "Bearer"

    status, _, _ = server.post("/oauth/token", dict(form))
    assert status == 400  # single-use


def test_refresh_rotates(server: Client) -> None:
    tokens = _issue(server)
    status, body, _ = server.post(
        "/oauth/token",
        {"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"]},
    )
    assert status == 200
    assert json.loads(body)["access_token"] != tokens["access_token"]

    status, _, _ = server.post(
        "/oauth/token",
        {"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"]},
    )
    assert status == 400  # the presented token died on rotation


# --- an OAuth token actually reaching the tools -----------------------------


def test_oauth_token_lists_all_four_tools(server: Client) -> None:
    tokens = _issue(server)
    result = server.rpc("tools/list", str(tokens["access_token"]))
    names = {t["name"] for t in result["result"]["tools"]}
    assert {"search", "fetch", "recap", "overview"} <= names


def test_oauth_token_can_call_recap(server: Client) -> None:
    tokens = _issue(server)
    result = server.rpc(
        "tools/call", str(tokens["access_token"]), {"name": "recap", "arguments": {}}
    )
    assert "2026-07-27" in json.dumps(result)


def test_prompts_are_exposed(server: Client) -> None:
    tokens = _issue(server)
    result = server.rpc("prompts/list", str(tokens["access_token"]))
    names = {p["name"] for p in result["result"]["prompts"]}
    assert {"catch_me_up", "what_was_said_about"} <= names


def test_static_loopback_token_still_works(server: Client) -> None:
    """Connector mode must not migrate Claude Code or a co-located agent."""
    token = (Path.home() / ".config" / "huske" / "mcp_token").read_text().strip()
    result = server.rpc("tools/list", token)
    assert result["result"]["tools"]


def test_a_bogus_token_is_refused(server: Client) -> None:
    status, _, _ = server.post(
        "/mcp",
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        json_body=True,
        authorization="Bearer not-a-real-token",
        accept="application/json, text/event-stream",
    )
    assert status == 401
