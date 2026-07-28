"""The embedded OAuth 2.1 authorization server: stdlib-only, no extra needed.

Covers the properties that actually keep a public transcript endpoint shut:
single-use codes, PKCE binding, audience binding, refresh rotation, exact
redirect matching, and passphrase lockout.
"""

from __future__ import annotations

import base64
import hashlib
from pathlib import Path

import pytest

from huske.mcp.oauth import (
    LOCKOUT_AFTER_FAILURES,
    READ_SCOPE,
    AuthorizationServer,
    OAuthError,
    OAuthStore,
    canonical_resource,
    hash_password,
    load_password_hash,
    save_password_hash,
    validate_redirect_uri,
    verify_password,
)

RESOURCE = "https://huske.example.com/mcp"
PASSWORD = "correct horse battery staple"
REDIRECT = "https://claude.ai/api/mcp/auth_callback"


def _verifier_and_challenge() -> tuple[str, str]:
    verifier = "a" * 64
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return verifier, base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


@pytest.fixture
def server() -> AuthorizationServer:
    return AuthorizationServer(
        resource=RESOURCE,
        store=OAuthStore.memory(),
        password_hash=hash_password(PASSWORD),
    )


def _register(server: AuthorizationServer, redirect: str = REDIRECT) -> str:
    reg = server.register({"redirect_uris": [redirect], "client_name": "Claude"})
    return str(reg["client_id"])


def _authorize_params(client_id: str, challenge: str, **extra: str) -> dict[str, str]:
    params = {
        "client_id": client_id,
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "resource": RESOURCE,
        "state": "xyz",
    }
    params.update(extra)
    return params


def _code_from(location: str) -> str:
    from urllib.parse import parse_qs, urlsplit

    return parse_qs(urlsplit(location).query)["code"][0]


# --- password hashing -------------------------------------------------------


def test_password_roundtrip() -> None:
    stored = hash_password(PASSWORD)
    assert verify_password(PASSWORD, stored)
    assert not verify_password(PASSWORD + "!", stored)


def test_password_hash_is_salted() -> None:
    assert hash_password(PASSWORD) != hash_password(PASSWORD)


def test_verify_rejects_garbage_hash() -> None:
    assert not verify_password(PASSWORD, "not-a-hash")
    assert not verify_password(PASSWORD, "")


def test_saved_password_file_is_owner_only(tmp_path: Path) -> None:
    path = save_password_hash(PASSWORD, tmp_path / "mcp_password")
    assert path.stat().st_mode & 0o777 == 0o600
    stored = load_password_hash(path)
    assert stored is not None and verify_password(PASSWORD, stored)


def test_load_password_hash_missing_is_none(tmp_path: Path) -> None:
    assert load_password_hash(tmp_path / "absent") is None


# --- canonical resource / redirect validation -------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("https://HUSKE.example.com/mcp", "https://huske.example.com/mcp"),
        ("https://huske.example.com/mcp/", "https://huske.example.com/mcp"),
        ("https://huske.example.com:443/mcp", "https://huske.example.com/mcp"),
        ("https://huske.example.com:8443/mcp", "https://huske.example.com:8443/mcp"),
        ("https://huske.example.com", "https://huske.example.com"),
    ],
)
def test_canonical_resource(raw: str, expected: str) -> None:
    assert canonical_resource(raw) == expected


def test_canonical_resource_rejects_relative() -> None:
    with pytest.raises(ValueError, match="absolute"):
        canonical_resource("huske.example.com/mcp")


def test_redirect_uri_allows_https_and_loopback() -> None:
    assert validate_redirect_uri(REDIRECT) == REDIRECT
    assert validate_redirect_uri("http://127.0.0.1:9231/callback")
    assert validate_redirect_uri("http://localhost:9231/callback")


@pytest.mark.parametrize(
    "bad",
    [
        "http://evil.example.com/cb",  # plaintext, not loopback
        "https://evil.example.com/cb#frag",  # fragment
        "/relative",
    ],
)
def test_redirect_uri_rejects(bad: str) -> None:
    with pytest.raises(OAuthError):
        validate_redirect_uri(bad)


# --- dynamic client registration -------------------------------------------


def test_register_issues_public_client(server: AuthorizationServer) -> None:
    reg = server.register({"redirect_uris": [REDIRECT], "client_name": "Claude"})
    assert reg["token_endpoint_auth_method"] == "none"
    assert "client_secret" not in reg
    assert reg["redirect_uris"] == [REDIRECT]
    assert reg["scope"] == READ_SCOPE
    assert str(reg["client_id"]).startswith("huske-")


def test_register_requires_redirect_uris(server: AuthorizationServer) -> None:
    with pytest.raises(OAuthError) as exc:
        server.register({"client_name": "Claude"})
    assert exc.value.error == "invalid_redirect_uri"


def test_register_rejects_confidential_client(server: AuthorizationServer) -> None:
    with pytest.raises(OAuthError, match="public clients only"):
        server.register(
            {"redirect_uris": [REDIRECT], "token_endpoint_auth_method": "client_secret_post"}
        )


def test_register_rejects_unknown_grant(server: AuthorizationServer) -> None:
    with pytest.raises(OAuthError, match="grant_types"):
        server.register({"redirect_uris": [REDIRECT], "grant_types": ["implicit"]})


# --- metadata ---------------------------------------------------------------


def test_metadata_advertises_what_clients_require(server: AuthorizationServer) -> None:
    meta = server.metadata()
    assert meta["issuer"] == "https://huske.example.com"
    assert meta["code_challenge_methods_supported"] == ["S256"]
    assert meta["token_endpoint_auth_methods_supported"] == ["none"]
    assert "authorization_code" in meta["grant_types_supported"]
    assert "refresh_token" in meta["grant_types_supported"]
    assert meta["registration_endpoint"].endswith("/oauth/register")
    assert meta["authorization_response_iss_parameter_supported"] is True


def test_protected_resource_metadata_points_at_this_as(server: AuthorizationServer) -> None:
    prm = server.protected_resource_metadata()
    assert prm["resource"] == RESOURCE
    assert prm["authorization_servers"] == ["https://huske.example.com"]
    assert prm["scopes_supported"] == [READ_SCOPE]


# --- authorization request validation --------------------------------------


def test_authorize_requires_known_client(server: AuthorizationServer) -> None:
    _, challenge = _verifier_and_challenge()
    with pytest.raises(OAuthError, match="unknown client_id"):
        server.parse_authorization_request(_authorize_params("nope", challenge))


def test_authorize_requires_exact_redirect_match(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    params = _authorize_params(client_id, challenge)
    params["redirect_uri"] = REDIRECT + "/extra"
    with pytest.raises(OAuthError, match="does not match a registered value"):
        server.parse_authorization_request(params)


def test_authorize_requires_pkce_s256(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    with pytest.raises(OAuthError, match="PKCE is required"):
        server.parse_authorization_request(_authorize_params(client_id, ""))
    with pytest.raises(OAuthError, match="must be S256"):
        server.parse_authorization_request(
            _authorize_params(client_id, challenge, code_challenge_method="plain")
        )


def test_authorize_rejects_foreign_resource(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    with pytest.raises(OAuthError) as exc:
        server.parse_authorization_request(
            _authorize_params(client_id, challenge, resource="https://elsewhere.example.com/mcp")
        )
    assert exc.value.error == "invalid_target"


def test_authorize_accepts_origin_only_resource(server: AuthorizationServer) -> None:
    """Some clients send the origin rather than the full endpoint URL."""
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(
        _authorize_params(client_id, challenge, resource="https://huske.example.com")
    )
    assert request.resource == RESOURCE


def test_authorize_defaults_resource_when_absent(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    params = _authorize_params(client_id, challenge)
    del params["resource"]
    assert server.parse_authorization_request(params).resource == RESOURCE


def test_authorize_tolerates_offline_access_scope(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(
        _authorize_params(client_id, challenge, scope=f"{READ_SCOPE} offline_access")
    )
    assert request.scope == READ_SCOPE


def test_authorize_rejects_unknown_scope(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    with pytest.raises(OAuthError, match="unknown scope"):
        server.parse_authorization_request(
            _authorize_params(client_id, challenge, scope="transcripts:write")
        )


# --- the code → token flow --------------------------------------------------


def test_full_authorization_code_flow(server: AuthorizationServer) -> None:
    client_id = _register(server)
    verifier, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))

    location = server.complete_authorization(request, PASSWORD)
    assert location.startswith(REDIRECT + "?")
    assert "state=xyz" in location
    # RFC 9207: the client validates this against the issuer it discovered.
    assert "iss=https%3A%2F%2Fhuske.example.com" in location

    tokens = server.token(
        {
            "grant_type": "authorization_code",
            "code": _code_from(location),
            "code_verifier": verifier,
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "resource": RESOURCE,
        }
    )
    assert tokens["token_type"] == "Bearer"
    assert tokens["scope"] == READ_SCOPE
    info = server.validate_access_token(str(tokens["access_token"]))
    assert info is not None
    assert info.resource == RESOURCE
    assert info.client_id == client_id


def test_wrong_password_is_denied_and_mints_no_code(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    with pytest.raises(OAuthError) as exc:
        server.complete_authorization(request, "wrong")
    assert exc.value.error == "access_denied"


def test_repeated_failures_lock_the_login(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    for _ in range(LOCKOUT_AFTER_FAILURES):
        with pytest.raises(OAuthError):
            server.complete_authorization(request, "wrong")
    assert server.login_locked_for() > 0
    # Even the *correct* passphrase is refused while locked.
    with pytest.raises(OAuthError) as exc:
        server.complete_authorization(request, PASSWORD)
    assert exc.value.status == 429


def test_success_clears_the_failure_counter(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    with pytest.raises(OAuthError):
        server.complete_authorization(request, "wrong")
    server.complete_authorization(request, PASSWORD)
    assert server.login_locked_for() == 0


def test_authorization_without_a_passphrase_refuses_to_issue() -> None:
    server = AuthorizationServer(
        resource=RESOURCE, store=OAuthStore.memory(), password_hash=None
    )
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    with pytest.raises(OAuthError) as exc:
        server.complete_authorization(request, "anything")
    assert exc.value.status == 500


def test_code_is_single_use(server: AuthorizationServer) -> None:
    client_id = _register(server)
    verifier, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    code = _code_from(server.complete_authorization(request, PASSWORD))
    form = {"grant_type": "authorization_code", "code": code, "code_verifier": verifier}

    server.token(dict(form))
    with pytest.raises(OAuthError, match="unknown, used, or expired"):
        server.token(dict(form))


def test_pkce_mismatch_rejects_the_code(server: AuthorizationServer) -> None:
    client_id = _register(server)
    _, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    code = _code_from(server.complete_authorization(request, PASSWORD))
    with pytest.raises(OAuthError, match="PKCE verification failed"):
        server.token(
            {"grant_type": "authorization_code", "code": code, "code_verifier": "b" * 64}
        )


def test_code_bound_to_its_redirect_uri(server: AuthorizationServer) -> None:
    client_id = _register(server)
    server.register({"redirect_uris": ["https://other.example.com/cb"]})
    verifier, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    code = _code_from(server.complete_authorization(request, PASSWORD))
    with pytest.raises(OAuthError, match="redirect_uri does not match"):
        server.token(
            {
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": "https://other.example.com/cb",
            }
        )


def test_code_cannot_be_swapped_onto_another_audience(server: AuthorizationServer) -> None:
    client_id = _register(server)
    verifier, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    code = _code_from(server.complete_authorization(request, PASSWORD))
    with pytest.raises(OAuthError) as exc:
        server.token(
            {
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "resource": "https://elsewhere.example.com/mcp",
            }
        )
    assert exc.value.error == "invalid_target"


def test_unsupported_grant_type(server: AuthorizationServer) -> None:
    with pytest.raises(OAuthError, match=r"unsupported grant_type"):
        server.token({"grant_type": "password", "username": "x"})


# --- refresh ----------------------------------------------------------------


def _issue(server: AuthorizationServer) -> dict[str, object]:
    client_id = _register(server)
    verifier, challenge = _verifier_and_challenge()
    request = server.parse_authorization_request(_authorize_params(client_id, challenge))
    code = _code_from(server.complete_authorization(request, PASSWORD))
    return server.token(
        {"grant_type": "authorization_code", "code": code, "code_verifier": verifier}
    )


def test_refresh_issues_a_new_pair(server: AuthorizationServer) -> None:
    first = _issue(server)
    second = server.token(
        {"grant_type": "refresh_token", "refresh_token": str(first["refresh_token"])}
    )
    assert second["access_token"] != first["access_token"]
    assert server.validate_access_token(str(second["access_token"])) is not None


def test_refresh_token_rotates_and_old_one_dies(server: AuthorizationServer) -> None:
    first = _issue(server)
    used = str(first["refresh_token"])
    server.token({"grant_type": "refresh_token", "refresh_token": used})
    with pytest.raises(OAuthError, match="unknown, revoked, or expired"):
        server.token({"grant_type": "refresh_token", "refresh_token": used})


def test_revoke_kills_an_access_token(server: AuthorizationServer) -> None:
    tokens = _issue(server)
    access = str(tokens["access_token"])
    assert server.validate_access_token(access) is not None
    server.revoke({"token": access})
    assert server.validate_access_token(access) is None


def test_revoke_unknown_token_is_a_noop(server: AuthorizationServer) -> None:
    server.revoke({"token": "never-issued"})  # must not raise


def test_revoke_all_cuts_off_every_client(server: AuthorizationServer) -> None:
    a = _issue(server)
    b = _issue(server)
    assert server.store.revoke_all_tokens() >= 4  # two access + two refresh
    assert server.validate_access_token(str(a["access_token"])) is None
    assert server.validate_access_token(str(b["access_token"])) is None


def test_expired_access_token_is_rejected() -> None:
    server = AuthorizationServer(
        resource=RESOURCE,
        store=OAuthStore.memory(),
        password_hash=hash_password(PASSWORD),
        access_ttl=-1.0,  # already expired on issue
    )
    tokens = _issue(server)
    assert server.validate_access_token(str(tokens["access_token"])) is None


def test_unknown_token_is_rejected(server: AuthorizationServer) -> None:
    assert server.validate_access_token("nope") is None


# --- storage ----------------------------------------------------------------


def test_store_file_is_owner_only(tmp_path: Path) -> None:
    store = OAuthStore.open(tmp_path / "oauth.db")
    try:
        assert (tmp_path / "oauth.db").stat().st_mode & 0o777 == 0o600
    finally:
        store.close()


def test_store_never_persists_a_usable_token(tmp_path: Path) -> None:
    """A stolen oauth.db must not hand over credentials."""
    store = OAuthStore.open(tmp_path / "oauth.db")
    try:
        store.put_token(
            "super-secret-token",
            kind="access",
            client_id="c1",
            resource=RESOURCE,
            scope=READ_SCOPE,
            ttl=60,
        )
    finally:
        store.close()
    assert b"super-secret-token" not in (tmp_path / "oauth.db").read_bytes()


def test_client_registrations_are_capped(server: AuthorizationServer) -> None:
    from huske.mcp.oauth import MAX_CLIENTS

    for _ in range(MAX_CLIENTS + 8):
        server.register({"redirect_uris": [REDIRECT]})
    assert server.store.count_clients() <= MAX_CLIENTS
