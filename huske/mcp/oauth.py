"""Single-tenant OAuth 2.1 authorization server for the huske MCP endpoint.

Why huske ships its own authorization server instead of requiring an external
IdP: the *only* way Claude (iOS / desktop / web) and ChatGPT can attach a remote
MCP server is the MCP authorization spec — OAuth 2.1 with PKCE, Protected
Resource Metadata (RFC 9728), and either Client ID Metadata Documents or
Dynamic Client Registration (RFC 7591). Neither client lets a user paste a
static bearer header into a connector. So a huske server that wants to be
reachable from a phone needs a real OAuth authorization server, and standing up
Keycloak next to a 200-line ingest daemon would dwarf the thing it protects.
See docs/adr/0008-public-mcp-connector.md.

The scope that makes this tractable: **one user, one credential, one read-only
scope.** There are no accounts, no consent registry, no user database — the
"login" is a single scrypt-hashed passphrase, and every issued token grants
exactly ``transcripts:read`` on exactly one resource. That collapses an
authorization server to token bookkeeping plus one HTML form.

Stdlib-only (``sqlite3`` + ``hashlib`` + ``secrets``), so the module imports
without the ``huske[mcp]`` extra and is unit-testable on its own.

Specs implemented: OAuth 2.1 authorization code + refresh, RFC 7591 (dynamic
client registration), RFC 7636 (PKCE, S256 only), RFC 8414 (authorization
server metadata), RFC 8707 (resource indicators — tokens are audience-bound),
RFC 9207 (``iss`` in the authorization response), RFC 7009 (revocation).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlsplit

# The one scope. A huske connector token can search and read transcripts; there
# is nothing else to authorize, and keeping the set at one element means clients
# never have to guess (see the MCP spec's scope-selection strategy).
READ_SCOPE = "transcripts:read"

CODE_TTL_SECONDS = 300
DEFAULT_ACCESS_TTL_SECONDS = 12 * 3600
DEFAULT_REFRESH_TTL_SECONDS = 90 * 86400

# A DCR endpoint is an unauthenticated write surface, so it needs a ceiling.
# Each real client registers once; anything past this is noise, so the oldest
# client holding no live token is evicted to make room.
MAX_CLIENTS = 64

# Failed-passphrase backoff. Global rather than per-IP on purpose: this guards a
# single-tenant secret, and an attacker who can rotate source addresses would
# walk straight through a per-IP counter.
LOCKOUT_AFTER_FAILURES = 5
LOCKOUT_MAX_SECONDS = 900.0


class OAuthError(Exception):
    """An OAuth-shaped error: ``error`` code plus an HTTP status."""

    def __init__(self, error: str, description: str = "", *, status: int = 400) -> None:
        super().__init__(description or error)
        self.error = error
        self.description = description
        self.status = status

    def to_dict(self) -> dict[str, str]:
        payload = {"error": self.error}
        if self.description:
            payload["error_description"] = self.description
        return payload


# --- passphrase hashing -----------------------------------------------------
#
# scrypt where available (memory-hard, so a stolen hash resists GPU cracking),
# PBKDF2-HMAC-SHA256 as the fallback for a CPython built against an OpenSSL
# without scrypt. The stored string carries its own parameters so an older hash
# keeps verifying after a default change.

_SCRYPT_N = 2**14
_SCRYPT_R = 8
_SCRYPT_P = 1
_PBKDF2_ROUNDS = 600_000


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _unb64(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def hash_password(password: str) -> str:
    """Return a self-describing hash string for ``password``."""
    salt = secrets.token_bytes(16)
    try:
        dk = hashlib.scrypt(
            password.encode("utf-8"), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32
        )
    except (ValueError, AttributeError):  # pragma: no cover - OpenSSL without scrypt
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, _PBKDF2_ROUNDS)
        return f"pbkdf2_sha256${_PBKDF2_ROUNDS}${_b64(salt)}${_b64(dk)}"
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${_b64(salt)}${_b64(dk)}"


def verify_password(password: str, stored: str) -> bool:
    """Constant-time check of ``password`` against a :func:`hash_password` string."""
    parts = stored.strip().split("$")
    try:
        if parts[0] == "scrypt":
            _, n_s, r_s, p_s, salt_s, dk_s = parts
            expected = _unb64(dk_s)
            actual = hashlib.scrypt(
                password.encode("utf-8"),
                salt=_unb64(salt_s),
                n=int(n_s),
                r=int(r_s),
                p=int(p_s),
                dklen=len(expected),
            )
        elif parts[0] == "pbkdf2_sha256":
            _, rounds_s, salt_s, dk_s = parts
            expected = _unb64(dk_s)
            actual = hashlib.pbkdf2_hmac(
                "sha256", password.encode("utf-8"), _unb64(salt_s), int(rounds_s), len(expected)
            )
        else:
            return False
    except (ValueError, TypeError, IndexError, AttributeError):
        return False
    return hmac.compare_digest(actual, expected)


def password_file_path() -> Path:
    """Where the connector passphrase hash lives (mode ``0600``)."""
    return Path.home() / ".config" / "huske" / "mcp_password"


def default_store_path() -> Path:
    """Where issued clients/tokens are recorded (mode ``0600``).

    Beside ``mcp_token`` and ``ingest_token`` rather than under ``index_root``:
    this file is credential material, not a search artifact, and it must survive
    ``huske index --rebuild`` untouched.
    """
    return Path.home() / ".config" / "huske" / "oauth.db"


def load_password_hash(path: Path | None = None) -> str | None:
    """Return the stored passphrase hash, or ``None`` when none is set."""
    target = path or password_file_path()
    try:
        value = target.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return None
    return value or None


def save_password_hash(password: str, path: Path | None = None) -> Path:
    """Hash ``password`` and write it with ``0600`` from the first byte."""
    target = path or password_file_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(hash_password(password) + "\n")
    return target


# --- storage ----------------------------------------------------------------


def _token_fingerprint(token: str) -> str:
    """sha256 of a token — what we persist, so a stolen DB yields no credentials.

    A plain digest (not a slow KDF) is right here: these are 256-bit random
    strings, so there is no dictionary to attack.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(slots=True)
class ClientRecord:
    client_id: str
    client_name: str
    redirect_uris: list[str]
    created_at: float


@dataclass(slots=True)
class TokenInfo:
    """A live access token's claims."""

    client_id: str
    resource: str
    scope: str
    expires_at: float


class OAuthStore:
    """SQLite-backed client / code / token records. One file, mode ``0600``."""

    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn
        self._create_schema()

    @classmethod
    def open(cls, db_path: Path) -> OAuthStore:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        # Create the file ourselves so it is never briefly world-readable —
        # sqlite3.connect() would use the process umask.
        if not db_path.exists():
            os.close(os.open(str(db_path), os.O_WRONLY | os.O_CREAT, 0o600))
        conn = sqlite3.connect(str(db_path), check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return cls(conn)

    @classmethod
    def memory(cls) -> OAuthStore:
        """An in-memory store (tests)."""
        return cls(sqlite3.connect(":memory:", check_same_thread=False))

    def _create_schema(self) -> None:
        c = self._conn
        c.execute(
            "CREATE TABLE IF NOT EXISTS oauth_clients ("
            "client_id TEXT PRIMARY KEY, client_name TEXT, redirect_uris TEXT, "
            "created_at REAL)"
        )
        c.execute(
            "CREATE TABLE IF NOT EXISTS oauth_codes ("
            "code_hash TEXT PRIMARY KEY, client_id TEXT, redirect_uri TEXT, "
            "code_challenge TEXT, resource TEXT, scope TEXT, expires_at REAL, "
            "used INTEGER DEFAULT 0)"
        )
        c.execute(
            "CREATE TABLE IF NOT EXISTS oauth_tokens ("
            "token_hash TEXT PRIMARY KEY, kind TEXT, client_id TEXT, resource TEXT, "
            "scope TEXT, expires_at REAL, revoked INTEGER DEFAULT 0, created_at REAL)"
        )
        c.execute(
            "CREATE TABLE IF NOT EXISTS oauth_state (key TEXT PRIMARY KEY, value TEXT)"
        )
        c.commit()

    def close(self) -> None:
        self._conn.close()

    # -- clients -----------------------------------------------------------

    def add_client(self, record: ClientRecord) -> None:
        self._prune_clients()
        self._conn.execute(
            "INSERT OR REPLACE INTO oauth_clients(client_id, client_name, redirect_uris, created_at) "
            "VALUES (?,?,?,?)",
            (
                record.client_id,
                record.client_name,
                json.dumps(record.redirect_uris),
                record.created_at,
            ),
        )
        self._conn.commit()

    def get_client(self, client_id: str) -> ClientRecord | None:
        row = self._conn.execute(
            "SELECT client_id, client_name, redirect_uris, created_at "
            "FROM oauth_clients WHERE client_id = ?",
            (client_id,),
        ).fetchone()
        if row is None:
            return None
        return ClientRecord(
            client_id=str(row[0]),
            client_name=str(row[1]),
            redirect_uris=list(json.loads(row[2])),
            created_at=float(row[3]),
        )

    def count_clients(self) -> int:
        return int(self._conn.execute("SELECT count(*) FROM oauth_clients").fetchone()[0])

    def _prune_clients(self) -> None:
        """Evict the oldest clients holding no live token, keeping room for one more."""
        while self.count_clients() >= MAX_CLIENTS:
            row = self._conn.execute(
                "SELECT client_id FROM oauth_clients WHERE client_id NOT IN "
                "(SELECT client_id FROM oauth_tokens WHERE revoked = 0 AND expires_at > ?) "
                "ORDER BY created_at LIMIT 1",
                (time.time(),),
            ).fetchone()
            if row is None:
                # Every client is live; drop the very oldest rather than refuse
                # to register, so a new device can always be added.
                row = self._conn.execute(
                    "SELECT client_id FROM oauth_clients ORDER BY created_at LIMIT 1"
                ).fetchone()
            if row is None:  # pragma: no cover - table is non-empty by the guard
                return
            self._conn.execute("DELETE FROM oauth_clients WHERE client_id = ?", (row[0],))
            self._conn.execute("DELETE FROM oauth_tokens WHERE client_id = ?", (row[0],))
            self._conn.commit()

    # -- authorization codes ----------------------------------------------

    def put_code(
        self,
        code: str,
        *,
        client_id: str,
        redirect_uri: str,
        code_challenge: str,
        resource: str,
        scope: str,
        ttl: float = CODE_TTL_SECONDS,
    ) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO oauth_codes(code_hash, client_id, redirect_uri, "
            "code_challenge, resource, scope, expires_at, used) VALUES (?,?,?,?,?,?,?,0)",
            (
                _token_fingerprint(code),
                client_id,
                redirect_uri,
                code_challenge,
                resource,
                scope,
                time.time() + ttl,
            ),
        )
        self._conn.commit()

    def consume_code(self, code: str) -> dict[str, Any] | None:
        """Atomically mark a code used and return it, or ``None`` if unusable.

        Single-use is enforced by the ``used = 0`` predicate on the UPDATE, so a
        replayed code loses the race rather than being handed out twice.
        """
        fingerprint = _token_fingerprint(code)
        cur = self._conn.execute(
            "UPDATE oauth_codes SET used = 1 WHERE code_hash = ? AND used = 0 AND expires_at > ?",
            (fingerprint, time.time()),
        )
        if cur.rowcount != 1:
            self._conn.commit()
            return None
        row = self._conn.execute(
            "SELECT client_id, redirect_uri, code_challenge, resource, scope "
            "FROM oauth_codes WHERE code_hash = ?",
            (fingerprint,),
        ).fetchone()
        self._conn.commit()
        if row is None:  # pragma: no cover - just updated it
            return None
        return {
            "client_id": str(row[0]),
            "redirect_uri": str(row[1]),
            "code_challenge": str(row[2]),
            "resource": str(row[3]),
            "scope": str(row[4]),
        }

    # -- tokens ------------------------------------------------------------

    def put_token(
        self,
        token: str,
        *,
        kind: str,
        client_id: str,
        resource: str,
        scope: str,
        ttl: float,
    ) -> None:
        now = time.time()
        self._conn.execute(
            "INSERT OR REPLACE INTO oauth_tokens(token_hash, kind, client_id, resource, "
            "scope, expires_at, revoked, created_at) VALUES (?,?,?,?,?,?,0,?)",
            (_token_fingerprint(token), kind, client_id, resource, scope, now + ttl, now),
        )
        self._conn.commit()

    def get_token(self, token: str, *, kind: str) -> TokenInfo | None:
        row = self._conn.execute(
            "SELECT client_id, resource, scope, expires_at FROM oauth_tokens "
            "WHERE token_hash = ? AND kind = ? AND revoked = 0 AND expires_at > ?",
            (_token_fingerprint(token), kind, time.time()),
        ).fetchone()
        if row is None:
            return None
        return TokenInfo(
            client_id=str(row[0]),
            resource=str(row[1]),
            scope=str(row[2]),
            expires_at=float(row[3]),
        )

    def revoke_token(self, token: str) -> bool:
        cur = self._conn.execute(
            "UPDATE oauth_tokens SET revoked = 1 WHERE token_hash = ?",
            (_token_fingerprint(token),),
        )
        self._conn.commit()
        return cur.rowcount > 0

    def revoke_client_tokens(self, client_id: str) -> int:
        cur = self._conn.execute(
            "UPDATE oauth_tokens SET revoked = 1 WHERE client_id = ?", (client_id,)
        )
        self._conn.commit()
        return int(cur.rowcount)

    def revoke_all_tokens(self) -> int:
        cur = self._conn.execute("UPDATE oauth_tokens SET revoked = 1 WHERE revoked = 0")
        self._conn.commit()
        return int(cur.rowcount)

    def purge_expired(self) -> None:
        now = time.time()
        self._conn.execute("DELETE FROM oauth_codes WHERE expires_at < ?", (now - 3600,))
        self._conn.execute("DELETE FROM oauth_tokens WHERE expires_at < ?", (now - 86400,))
        self._conn.commit()

    def live_token_count(self) -> int:
        return int(
            self._conn.execute(
                "SELECT count(*) FROM oauth_tokens WHERE kind = 'access' AND revoked = 0 "
                "AND expires_at > ?",
                (time.time(),),
            ).fetchone()[0]
        )

    # -- login backoff -----------------------------------------------------

    def _state(self, key: str) -> str | None:
        row = self._conn.execute("SELECT value FROM oauth_state WHERE key = ?", (key,)).fetchone()
        return str(row[0]) if row else None

    def _set_state(self, key: str, value: str) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO oauth_state(key, value) VALUES (?,?)", (key, value)
        )
        self._conn.commit()

    def lockout_remaining(self) -> float:
        raw = self._state("lockout_until")
        if raw is None:
            return 0.0
        return max(0.0, float(raw) - time.time())

    def record_login_failure(self) -> float:
        """Count a bad passphrase; return the seconds the AS is now locked for."""
        failures = int(self._state("login_failures") or "0") + 1
        self._set_state("login_failures", str(failures))
        if failures < LOCKOUT_AFTER_FAILURES:
            return 0.0
        # Double the wait for each failure past the threshold, capped so a
        # forgetful owner is never locked out for more than LOCKOUT_MAX_SECONDS.
        delay = min(LOCKOUT_MAX_SECONDS, 30.0 * (2.0 ** (failures - LOCKOUT_AFTER_FAILURES)))
        self._set_state("lockout_until", str(time.time() + delay))
        return delay

    def clear_login_failures(self) -> None:
        self._set_state("login_failures", "0")
        self._set_state("lockout_until", "0")


# --- the authorization server ----------------------------------------------


def canonical_resource(url: str) -> str:
    """Normalize an MCP endpoint URL to its RFC 8707 canonical resource form.

    Lowercased scheme+host, no default port, no trailing slash, no fragment or
    query — the string a token's audience is compared against.
    """
    parts = urlsplit(url.strip())
    if not parts.scheme or not parts.hostname:
        raise ValueError(f"not an absolute URL: {url!r}")
    scheme = parts.scheme.lower()
    host = parts.hostname.lower()
    netloc = host
    if parts.port and not (
        (scheme == "https" and parts.port == 443) or (scheme == "http" and parts.port == 80)
    ):
        netloc = f"{host}:{parts.port}"
    path = parts.path.rstrip("/")
    return f"{scheme}://{netloc}{path}"


def resource_origin(resource: str) -> str:
    """The scheme://host[:port] of a canonical resource — huske's OAuth issuer."""
    parts = urlsplit(resource)
    return f"{parts.scheme}://{parts.netloc}"


def _is_loopback_redirect(parts: Any) -> bool:
    return parts.scheme == "http" and (parts.hostname or "") in {"127.0.0.1", "localhost", "::1"}


def validate_redirect_uri(uri: str) -> str:
    """Accept an HTTPS redirect, or loopback HTTP for native/CLI clients.

    OAuth 2.1 permits ``http://127.0.0.1:<port>/...`` for native apps — the path
    Claude Code and ``mcp-remote`` take — and nothing else unencrypted. A
    fragment is always rejected (it would break the redirect).
    """
    parts = urlsplit(uri.strip())
    if not parts.scheme or not parts.hostname:
        raise OAuthError("invalid_redirect_uri", f"not an absolute URI: {uri!r}")
    if parts.fragment:
        raise OAuthError("invalid_redirect_uri", "redirect_uri must not contain a fragment")
    if parts.scheme == "https" or _is_loopback_redirect(parts):
        return uri.strip()
    raise OAuthError(
        "invalid_redirect_uri",
        "redirect_uri must be https, or http on a loopback address for a native client",
    )


@dataclass(slots=True)
class AuthRequest:
    """A validated ``/authorize`` request, ready to mint a code for."""

    client_id: str
    client_name: str
    redirect_uri: str
    code_challenge: str
    resource: str
    scope: str
    state: str = ""

    def as_form_fields(self) -> dict[str, str]:
        """The hidden fields the login form round-trips back to ``POST /authorize``.

        Carrying the request in the form keeps the AS stateless between GET and
        POST; every field is re-validated on the way back in, so a tampered
        field fails exactly as a forged first request would.
        """
        return {
            "client_id": self.client_id,
            "redirect_uri": self.redirect_uri,
            "code_challenge": self.code_challenge,
            "code_challenge_method": "S256",
            "resource": self.resource,
            "scope": self.scope,
            "state": self.state,
            "response_type": "code",
        }


class AuthorizationServer:
    """Single-tenant OAuth 2.1 AS guarding one MCP resource with one passphrase."""

    def __init__(
        self,
        *,
        resource: str,
        store: OAuthStore,
        password_hash: str | None,
        access_ttl: float = DEFAULT_ACCESS_TTL_SECONDS,
        refresh_ttl: float = DEFAULT_REFRESH_TTL_SECONDS,
        on_event: Callable[[str], None] | None = None,
    ) -> None:
        self.resource = canonical_resource(resource)
        self.issuer = resource_origin(self.resource)
        self.store = store
        self._password_hash = password_hash
        self.access_ttl = access_ttl
        self.refresh_ttl = refresh_ttl
        self._on_event = on_event

    def _event(self, message: str) -> None:
        if self._on_event is not None:
            self._on_event(message)

    # -- discovery ---------------------------------------------------------

    def metadata(self) -> dict[str, Any]:
        """RFC 8414 authorization server metadata."""
        return {
            "issuer": self.issuer,
            "authorization_endpoint": f"{self.issuer}/oauth/authorize",
            "token_endpoint": f"{self.issuer}/oauth/token",
            "registration_endpoint": f"{self.issuer}/oauth/register",
            "revocation_endpoint": f"{self.issuer}/oauth/revoke",
            "scopes_supported": [READ_SCOPE],
            "response_types_supported": ["code"],
            "response_modes_supported": ["query"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_methods_supported": ["none"],
            "revocation_endpoint_auth_methods_supported": ["none"],
            "code_challenge_methods_supported": ["S256"],
            "authorization_response_iss_parameter_supported": True,
            "service_documentation": "https://github.com/tiagomoraes/huske",
        }

    def protected_resource_metadata(self) -> dict[str, Any]:
        """RFC 9728 protected resource metadata — how a client finds this AS."""
        return {
            "resource": self.resource,
            "authorization_servers": [self.issuer],
            "scopes_supported": [READ_SCOPE],
            "bearer_methods_supported": ["header"],
            "resource_name": "huske transcripts",
            "resource_documentation": "https://github.com/tiagomoraes/huske/blob/main/docs/integrations.md",
        }

    # -- dynamic client registration (RFC 7591) ---------------------------

    def register(self, payload: dict[str, Any]) -> dict[str, Any]:
        raw_uris = payload.get("redirect_uris")
        if not isinstance(raw_uris, list) or not raw_uris:
            raise OAuthError("invalid_redirect_uri", "redirect_uris must be a non-empty array")
        if len(raw_uris) > 10:
            raise OAuthError("invalid_client_metadata", "too many redirect_uris")
        uris = [validate_redirect_uri(str(u)) for u in raw_uris]

        auth_method = str(payload.get("token_endpoint_auth_method") or "none")
        if auth_method != "none":
            # Public clients only: there is no secret to keep secret in a client
            # that runs on someone else's phone, and PKCE is what actually binds
            # the code to the requester.
            raise OAuthError(
                "invalid_client_metadata",
                "huske issues public clients only (token_endpoint_auth_method must be 'none')",
            )

        grant_types = payload.get("grant_types") or ["authorization_code", "refresh_token"]
        unsupported = {str(g) for g in grant_types} - {"authorization_code", "refresh_token"}
        if unsupported:
            raise OAuthError(
                "invalid_client_metadata",
                f"unsupported grant_types: {', '.join(sorted(unsupported))}",
            )

        client_id = f"huske-{secrets.token_urlsafe(16)}"
        name = str(payload.get("client_name") or "unnamed MCP client")[:120]
        record = ClientRecord(
            client_id=client_id,
            client_name=name,
            redirect_uris=uris,
            created_at=time.time(),
        )
        self.store.add_client(record)
        self._event(f"registered client {name!r} ({client_id})")
        return {
            "client_id": client_id,
            "client_id_issued_at": int(record.created_at),
            "client_name": name,
            "redirect_uris": uris,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": READ_SCOPE,
        }

    # -- authorization -----------------------------------------------------

    def parse_authorization_request(self, params: dict[str, str]) -> AuthRequest:
        """Validate an ``/authorize`` query. Raises :class:`OAuthError`.

        Errors here are deliberately *not* redirected back to the client: an
        unvalidated ``redirect_uri`` is exactly the open-redirect a confused
        deputy attack needs, so a bad request renders locally instead.
        """
        client_id = params.get("client_id", "").strip()
        client = self.store.get_client(client_id) if client_id else None
        if client is None:
            raise OAuthError("invalid_client", "unknown client_id — register first")

        redirect_uri = params.get("redirect_uri", "").strip()
        if not redirect_uri:
            if len(client.redirect_uris) != 1:
                raise OAuthError("invalid_request", "redirect_uri is required")
            redirect_uri = client.redirect_uris[0]
        if redirect_uri not in client.redirect_uris:
            # Exact match only (OAuth 2.1) — no prefix or wildcard matching.
            raise OAuthError("invalid_request", "redirect_uri does not match a registered value")

        if params.get("response_type", "").strip() != "code":
            raise OAuthError("unsupported_response_type", "only response_type=code is supported")

        challenge = params.get("code_challenge", "").strip()
        method = (params.get("code_challenge_method") or "").strip()
        if not challenge:
            raise OAuthError("invalid_request", "PKCE is required (code_challenge)")
        if method != "S256":
            raise OAuthError("invalid_request", "code_challenge_method must be S256")

        resource = self._check_resource(params.get("resource"))
        scope = self._check_scope(params.get("scope"))
        return AuthRequest(
            client_id=client.client_id,
            client_name=client.client_name,
            redirect_uri=redirect_uri,
            code_challenge=challenge,
            resource=resource,
            scope=scope,
            state=params.get("state", ""),
        )

    def _check_resource(self, value: str | None) -> str:
        """Bind the token audience (RFC 8707), tolerating an omitted parameter.

        The MCP spec says clients MUST send ``resource``; some send only the
        origin, and older ones send nothing. Anything that names *this* server is
        accepted and normalized; anything naming a different one is refused, so
        a token minted here can never be replayed at another resource.
        """
        if not value:
            return self.resource
        try:
            requested = canonical_resource(value)
        except ValueError as exc:
            raise OAuthError("invalid_target", f"malformed resource: {value!r}") from exc
        if requested in (self.resource, self.issuer):
            return self.resource
        raise OAuthError(
            "invalid_target",
            f"this server only issues tokens for {self.resource}",
        )

    def _check_scope(self, value: str | None) -> str:
        if not value:
            return READ_SCOPE
        requested = {s for s in value.replace(",", " ").split() if s}
        # `offline_access` is how some clients ask for a refresh token; huske
        # always issues one, so accept and drop it rather than fail the request.
        requested.discard("offline_access")
        unknown = requested - {READ_SCOPE}
        if unknown:
            raise OAuthError("invalid_scope", f"unknown scope(s): {' '.join(sorted(unknown))}")
        return READ_SCOPE

    def login_locked_for(self) -> float:
        return self.store.lockout_remaining()

    def complete_authorization(self, request: AuthRequest, password: str) -> str:
        """Check the passphrase and return the redirect URL carrying the code."""
        if self._password_hash is None:
            raise OAuthError(
                "server_error",
                "no connector passphrase is set — run `huske mcp set-password`",
                status=500,
            )
        locked = self.store.lockout_remaining()
        if locked > 0:
            raise OAuthError(
                "access_denied",
                f"too many failed attempts — try again in {int(locked) + 1}s",
                status=429,
            )
        if not verify_password(password, self._password_hash):
            delay = self.store.record_login_failure()
            self._event(f"failed passphrase attempt for client {request.client_id}")
            detail = f" — locked for {int(delay)}s" if delay else ""
            raise OAuthError("access_denied", f"incorrect passphrase{detail}", status=401)

        self.store.clear_login_failures()
        code = secrets.token_urlsafe(32)
        self.store.put_code(
            code,
            client_id=request.client_id,
            redirect_uri=request.redirect_uri,
            code_challenge=request.code_challenge,
            resource=request.resource,
            scope=request.scope,
        )
        self._event(f"authorized {request.client_name!r} ({request.client_id})")
        return self.redirect_url(request.redirect_uri, {"code": code, "state": request.state})

    def redirect_url(self, redirect_uri: str, params: dict[str, str]) -> str:
        """Append ``params`` (plus RFC 9207 ``iss``) to a validated redirect URI."""
        fields = {k: v for k, v in params.items() if v}
        fields["iss"] = self.issuer
        joiner = "&" if urlsplit(redirect_uri).query else "?"
        return f"{redirect_uri}{joiner}{urlencode(fields)}"

    # -- token endpoint ----------------------------------------------------

    def token(self, form: dict[str, str]) -> dict[str, Any]:
        grant = form.get("grant_type", "").strip()
        if grant == "authorization_code":
            return self._token_from_code(form)
        if grant == "refresh_token":
            return self._token_from_refresh(form)
        raise OAuthError("unsupported_grant_type", f"unsupported grant_type: {grant!r}")

    def _token_from_code(self, form: dict[str, str]) -> dict[str, Any]:
        code = form.get("code", "").strip()
        verifier = form.get("code_verifier", "").strip()
        if not code or not verifier:
            raise OAuthError("invalid_request", "code and code_verifier are required")

        record = self.store.consume_code(code)
        if record is None:
            raise OAuthError("invalid_grant", "authorization code is unknown, used, or expired")

        client_id = form.get("client_id", "").strip()
        if client_id and client_id != record["client_id"]:
            raise OAuthError("invalid_grant", "client_id does not match the authorization code")
        redirect_uri = form.get("redirect_uri", "").strip()
        if redirect_uri and redirect_uri != record["redirect_uri"]:
            raise OAuthError("invalid_grant", "redirect_uri does not match the authorization code")

        expected = _s256_challenge(verifier)
        if not hmac.compare_digest(expected, str(record["code_challenge"])):
            raise OAuthError("invalid_grant", "PKCE verification failed")

        # A `resource` on the token request must agree with the one the code was
        # issued for; otherwise a code could be swapped onto another audience.
        if form.get("resource"):
            requested = self._check_resource(form["resource"])
            if requested != record["resource"]:
                raise OAuthError("invalid_target", "resource does not match the authorization code")

        return self._issue_pair(
            client_id=str(record["client_id"]),
            resource=str(record["resource"]),
            scope=str(record["scope"]),
        )

    def _token_from_refresh(self, form: dict[str, str]) -> dict[str, Any]:
        refresh = form.get("refresh_token", "").strip()
        if not refresh:
            raise OAuthError("invalid_request", "refresh_token is required")
        info = self.store.get_token(refresh, kind="refresh")
        if info is None:
            raise OAuthError("invalid_grant", "refresh token is unknown, revoked, or expired")
        client_id = form.get("client_id", "").strip()
        if client_id and client_id != info.client_id:
            raise OAuthError("invalid_grant", "client_id does not match the refresh token")
        # Rotate: the presented refresh token dies here, so a stolen copy is
        # usable at most once and only before the real client next refreshes.
        self.store.revoke_token(refresh)
        return self._issue_pair(
            client_id=info.client_id, resource=info.resource, scope=info.scope
        )

    def _issue_pair(self, *, client_id: str, resource: str, scope: str) -> dict[str, Any]:
        access = secrets.token_urlsafe(32)
        refresh = secrets.token_urlsafe(32)
        self.store.put_token(
            access,
            kind="access",
            client_id=client_id,
            resource=resource,
            scope=scope,
            ttl=self.access_ttl,
        )
        self.store.put_token(
            refresh,
            kind="refresh",
            client_id=client_id,
            resource=resource,
            scope=scope,
            ttl=self.refresh_ttl,
        )
        self.store.purge_expired()
        return {
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": int(self.access_ttl),
            "refresh_token": refresh,
            "scope": scope,
        }

    def revoke(self, form: dict[str, str]) -> None:
        """RFC 7009. Always succeeds — an unknown token is already revoked."""
        token = form.get("token", "").strip()
        if token:
            self.store.revoke_token(token)

    # -- resource-server side ---------------------------------------------

    def validate_access_token(self, token: str) -> TokenInfo | None:
        """Return the token's claims when it is live and audience-bound to us."""
        info = self.store.get_token(token, kind="access")
        if info is None:
            return None
        if info.resource != self.resource:  # pragma: no cover - defense in depth
            return None
        return info


def _s256_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


# --- the login page ---------------------------------------------------------


def escape_html(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#39;")
    )


_PAGE_CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body {
  margin: 0; min-height: 100vh; display: grid; place-items: center;
  background: #0b0b0c; color: #ededef; padding: 24px;
  font: 15px/1.5 ui-sans-serif, -apple-system, "Segoe UI", sans-serif;
}
.card {
  width: 100%; max-width: 400px; background: #131315;
  border: 1px solid #26262a; border-radius: 14px; padding: 30px 28px;
}
.brand {
  display: flex; align-items: baseline; gap: 8px; margin-bottom: 22px;
  font-weight: 600; letter-spacing: -0.02em; font-size: 19px;
}
.brand span { font: 11px/1 ui-monospace, monospace; color: #8a8a92;
  letter-spacing: 0.08em; text-transform: uppercase; }
h1 { font-size: 15px; font-weight: 600; margin: 0 0 6px; }
p.sub { margin: 0 0 20px; color: #9a9aa2; font-size: 13px; }
p.sub b { color: #ededef; font-weight: 600; }
label { display: block; font: 11px/1 ui-monospace, monospace; color: #8a8a92;
  letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 8px; }
input {
  width: 100%; padding: 11px 13px; border-radius: 9px; font-size: 15px;
  background: #0b0b0c; border: 1px solid #2e2e34; color: #ededef;
}
input:focus { outline: none; border-color: #6f6ff0; }
button {
  width: 100%; margin-top: 16px; padding: 11px; border: 0; border-radius: 9px;
  background: #6f6ff0; color: #fff; font-size: 15px; font-weight: 600;
  cursor: pointer;
}
button:hover { background: #5c5ce8; }
.err {
  margin: 0 0 16px; padding: 10px 12px; border-radius: 9px; font-size: 13px;
  background: #2a1416; border: 1px solid #532025; color: #ff9f9f;
}
.scope {
  margin-top: 20px; padding-top: 16px; border-top: 1px solid #26262a;
  color: #8a8a92; font-size: 12px;
}
.scope code { font-family: ui-monospace, monospace; color: #b8b8c0; }
"""


def render_login_page(request: AuthRequest, *, error: str = "", note: str = "") -> str:
    """The passphrase prompt shown in the browser during ``/authorize``."""
    hidden = "\n".join(
        f'      <input type="hidden" name="{escape_html(k)}" value="{escape_html(v)}"/>'
        for k, v in request.as_form_fields().items()
        if v
    )
    error_html = f'    <p class="err">{escape_html(error)}</p>\n' if error else ""
    note_html = f"<br/>{escape_html(note)}" if note else ""
    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta name="robots" content="noindex,nofollow"/>
<title>huske — connect</title>
<style>{_PAGE_CSS}</style>
</head><body>
  <div class="card">
    <div class="brand">huske <span>connector</span></div>
    <h1>Allow <b>{escape_html(request.client_name)}</b> to read your transcripts?</h1>
    <p class="sub">Enter your huske connector passphrase to grant it access.{note_html}</p>
{error_html}    <form method="post" action="/oauth/authorize">
{hidden}
      <label for="p">passphrase</label>
      <input id="p" name="password" type="password" autocomplete="current-password"
             autofocus required/>
      <button type="submit">Allow access</button>
    </form>
    <div class="scope">
      Grants <code>{escape_html(READ_SCOPE)}</code> on <code>{escape_html(request.resource)}</code> —
      semantic search and read-only fetch of your transcripts. Revoke any time with
      <code>huske mcp revoke</code>.
    </div>
  </div>
</body></html>
"""
