"""The Huske Sync GitHub App: device-flow sign-in, token refresh, and the few
REST calls cloud sync needs.

Huske is an open-source desktop app, so it cannot keep a client secret. The
OAuth device flow (RFC 8628) and its refresh grant are designed for exactly
that case: GitHub issues a user access token for the app without a secret, and
refreshes it without one. The token can only reach repositories the user both
can write to and has shared with the app's installation, and the app requests
nothing but repository *Contents* (plus the mandatory *Metadata*) — it cannot
create, delete, or reconfigure repositories.

Standard library only (``urllib``); tokens never appear in reprs, logs, or
process arguments.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

#: Public identifiers of the app registered for Huske. Forks register their own
#: app and point at it with these environment variables.
_DEFAULT_CLIENT_ID = "Iv23liiM3l6GVTPgvoTx"
_DEFAULT_APP_SLUG = "huske-sync"

_DEVICE_CODE_URL = "https://github.com/login/device/code"
_TOKEN_URL = "https://github.com/login/oauth/access_token"
_API = "https://api.github.com"
_DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
_TIMEOUT = 30.0

_GITHUB_HTTPS_REMOTE = re.compile(
    r"^https://github\.com/(?P<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/"
    r"(?P<repo>[A-Za-z0-9._-]+?)(?:\.git)?/?$"
)


def client_id() -> str:
    return os.environ.get("HUSKE_GITHUB_APP_CLIENT_ID", _DEFAULT_CLIENT_ID)


def app_slug() -> str:
    return os.environ.get("HUSKE_GITHUB_APP_SLUG", _DEFAULT_APP_SLUG)


def install_url() -> str:
    """Where a user shares repositories with the app (or installs it)."""
    return f"https://github.com/apps/{app_slug()}/installations/new"


def authorizations_url() -> str:
    """Where a user revokes the app's sign-in on GitHub itself."""
    return "https://github.com/settings/apps/authorizations"


def installation_settings_url(installation_id: int) -> str:
    return f"https://github.com/settings/installations/{installation_id}"


def new_repository_url(name: str = "huske-transcripts") -> str:
    """GitHub's documented new-repository form, prefilled and private."""
    query = urllib.parse.urlencode(
        {
            "name": name,
            "visibility": "private",
            "description": "Private meeting transcripts published by Huske",
        },
        quote_via=urllib.parse.quote,
    )
    return f"https://github.com/new?{query}"


def parse_github_https_remote(remote: str) -> tuple[str, str] | None:
    """``https://github.com/owner/repo(.git)`` → ``(owner, repo)``; else None."""
    match = _GITHUB_HTTPS_REMOTE.fullmatch(remote.strip())
    if match is None or match["repo"] in {".", ".."}:
        return None
    return match["owner"], match["repo"]


def github_https_remote(full_name: str) -> str:
    owner, _, repo = full_name.partition("/")
    remote = f"https://github.com/{owner}/{repo}.git"
    if not owner or not repo or parse_github_https_remote(remote) is None:
        raise ValueError(f"not a GitHub repository name: {full_name!r}")
    return remote


class GitHubError(RuntimeError):
    """A GitHub sign-in or API call failed.

    ``kind`` is one of ``network``, ``denied``, ``expired``, ``revoked``,
    ``disabled``, or ``http``; only ``network`` is worth retrying unattended.
    """

    def __init__(self, message: str, *, kind: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.kind = kind
        self.retryable = retryable


@dataclass(frozen=True)
class TokenSet:
    """A user access token for the app, plus what's needed to renew it."""

    access_token: str = field(repr=False)
    access_expires_at: float | None
    refresh_token: str | None = field(repr=False, default=None)
    refresh_expires_at: float | None = None
    login: str = ""

    @classmethod
    def from_response(
        cls, payload: dict[str, Any], *, now: float, login: str = ""
    ) -> TokenSet:
        def deadline(key: str) -> float | None:
            seconds = payload.get(key)
            return now + float(seconds) if seconds else None

        return cls(
            access_token=str(payload["access_token"]),
            access_expires_at=deadline("expires_in"),
            refresh_token=payload.get("refresh_token") or None,
            refresh_expires_at=deadline("refresh_token_expires_in"),
            login=login,
        )

    def needs_refresh(self, now: float, margin: float) -> bool:
        return self.access_expires_at is not None and now >= self.access_expires_at - margin

    def can_refresh(self, now: float) -> bool:
        if not self.refresh_token:
            return False
        return self.refresh_expires_at is None or now < self.refresh_expires_at

    def with_login(self, login: str) -> TokenSet:
        return TokenSet(
            access_token=self.access_token,
            access_expires_at=self.access_expires_at,
            refresh_token=self.refresh_token,
            refresh_expires_at=self.refresh_expires_at,
            login=login,
        )

    def to_json(self) -> str:
        return json.dumps(
            {
                "access_token": self.access_token,
                "access_expires_at": self.access_expires_at,
                "refresh_token": self.refresh_token,
                "refresh_expires_at": self.refresh_expires_at,
                "login": self.login,
            },
            sort_keys=True,
        )

    @classmethod
    def from_json(cls, raw: str) -> TokenSet:
        data = json.loads(raw)
        return cls(
            access_token=str(data["access_token"]),
            access_expires_at=data.get("access_expires_at"),
            refresh_token=data.get("refresh_token"),
            refresh_expires_at=data.get("refresh_expires_at"),
            login=str(data.get("login") or ""),
        )


@dataclass(frozen=True)
class DeviceCode:
    device_code: str = field(repr=False)
    user_code: str
    verification_uri: str
    expires_in: int
    interval: int


@dataclass(frozen=True)
class Repository:
    full_name: str
    private: bool
    html_url: str


@dataclass(frozen=True)
class Installation:
    """The app's installation as the signed-in user can see it."""

    installed: bool
    installation_id: int | None = None
    #: ``"selected"`` (only chosen repositories) or ``"all"``.
    repository_selection: str | None = None
    repositories: tuple[Repository, ...] = ()


# -- HTTP ---------------------------------------------------------------------

Transport = Callable[[urllib.request.Request], tuple[int, bytes]]


def _urllib_transport(request: urllib.request.Request) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise GitHubError(
            f"can't reach GitHub — this Mac looks offline ({exc})",
            kind="network",
            retryable=True,
        ) from exc


#: Swapped out in tests; production always goes through ``urllib``.
transport: Transport = _urllib_transport


def _decode(body: bytes) -> Any:
    try:
        return json.loads(body or b"{}")
    except ValueError:
        return {}


def _post_form(url: str, fields: dict[str, str]) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(fields).encode(),
        headers={"Accept": "application/json"},
        method="POST",
    )
    status, body = transport(request)
    payload = _decode(body)
    if status >= 500:
        raise GitHubError(
            f"GitHub returned HTTP {status}", kind="network", retryable=True
        )
    return payload if isinstance(payload, dict) else {}


def api_get(path: str, token: str) -> tuple[int, Any]:
    request = urllib.request.Request(
        f"{_API}{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    status, body = transport(request)
    if status >= 500:
        raise GitHubError(
            f"GitHub returned HTTP {status}", kind="network", retryable=True
        )
    if status == 401:
        raise GitHubError(
            "GitHub no longer accepts Huske's sign-in — connect GitHub again",
            kind="revoked",
        )
    return status, _decode(body)


# -- Device flow --------------------------------------------------------------


def start_device_flow() -> DeviceCode:
    payload = _post_form(_DEVICE_CODE_URL, {"client_id": client_id()})
    error = payload.get("error")
    if error == "device_flow_disabled":
        raise GitHubError(
            "the Huske Sync app has device sign-in turned off", kind="disabled"
        )
    if error or "device_code" not in payload:
        raise GitHubError(
            f"GitHub refused to start sign-in ({error or 'unexpected response'})",
            kind="http",
        )
    return DeviceCode(
        device_code=str(payload["device_code"]),
        user_code=str(payload["user_code"]),
        verification_uri=str(payload["verification_uri"]),
        expires_in=int(payload.get("expires_in", 900)),
        interval=int(payload.get("interval", 5)),
    )


def wait_for_authorization(
    code: DeviceCode,
    *,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.time,
) -> TokenSet:
    """Poll until the user approves (or denies, or the code expires)."""
    interval = max(1, code.interval)
    deadline = clock() + code.expires_in
    while clock() < deadline:
        sleep(interval)
        try:
            payload = _post_form(
                _TOKEN_URL,
                {
                    "client_id": client_id(),
                    "device_code": code.device_code,
                    "grant_type": _DEVICE_GRANT,
                },
            )
        except GitHubError as exc:
            # A dropped or slow poll says nothing about the sign-in; the code
            # is still valid, so keep waiting until it expires.
            if exc.retryable:
                continue
            raise
        error = payload.get("error")
        if error == "authorization_pending":
            continue
        if error == "slow_down":
            interval = int(payload.get("interval", interval + 5))
            continue
        if error == "access_denied":
            raise GitHubError("sign-in was cancelled on GitHub", kind="denied")
        if error == "expired_token":
            break
        if error:
            raise GitHubError(f"GitHub refused the sign-in ({error})", kind="http")
        if "access_token" in payload:
            return TokenSet.from_response(payload, now=clock())
        raise GitHubError("GitHub sent an unexpected sign-in response", kind="http")
    raise GitHubError(
        "the sign-in code expired before it was approved — start again", kind="expired"
    )


def refresh(tokens: TokenSet, *, clock: Callable[[], float] = time.time) -> TokenSet:
    """Exchange the refresh token for a new pair.

    GitHub rotates both tokens and invalidates the previous access token at
    once, so callers must refresh under the sync lock (see ``credentials``).
    """
    if not tokens.refresh_token:
        raise GitHubError("the GitHub sign-in can't be renewed", kind="expired")
    payload = _post_form(
        _TOKEN_URL,
        {
            "client_id": client_id(),
            "grant_type": "refresh_token",
            "refresh_token": tokens.refresh_token,
        },
    )
    if "access_token" not in payload:
        raise GitHubError(
            "GitHub no longer accepts Huske's sign-in "
            f"({payload.get('error', 'refresh refused')}) — connect GitHub again",
            kind="revoked",
        )
    return TokenSet.from_response(payload, now=clock(), login=tokens.login)


# -- REST ---------------------------------------------------------------------


def fetch_login(token: str) -> str:
    status, payload = api_get("/user", token)
    if status != 200 or not isinstance(payload, dict) or not payload.get("login"):
        raise GitHubError(f"couldn't read the GitHub account (HTTP {status})", kind="http")
    return str(payload["login"])


def fetch_installation(token: str) -> Installation:
    """The app's installation that the signed-in user can see, if any."""
    status, payload = api_get("/user/installations?per_page=100", token)
    if status != 200 or not isinstance(payload, dict):
        raise GitHubError(f"couldn't list installations (HTTP {status})", kind="http")
    ours = [
        item
        for item in payload.get("installations", [])
        if isinstance(item, dict) and item.get("app_slug") == app_slug()
    ]
    if not ours:
        return Installation(installed=False)
    installation = ours[0]
    installation_id = int(installation["id"])
    repositories: list[Repository] = []
    for page in range(1, 11):
        status, data = api_get(
            f"/user/installations/{installation_id}/repositories?per_page=100&page={page}",
            token,
        )
        if status != 200 or not isinstance(data, dict):
            raise GitHubError(
                f"couldn't list shared repositories (HTTP {status})", kind="http"
            )
        batch = [
            Repository(
                full_name=str(item["full_name"]),
                private=bool(item.get("private")),
                html_url=str(item.get("html_url", "")),
            )
            for item in data.get("repositories", [])
            if isinstance(item, dict) and item.get("full_name")
        ]
        repositories.extend(batch)
        if len(batch) < 100:
            break
    return Installation(
        installed=True,
        installation_id=installation_id,
        repository_selection=str(installation.get("repository_selection") or "") or None,
        repositories=tuple(sorted(repositories, key=lambda repo: repo.full_name.lower())),
    )


def fetch_repository(token: str, full_name: str) -> Repository | None:
    """``None`` when the repository doesn't exist or isn't shared with the app."""
    status, payload = api_get(f"/repos/{full_name}", token)
    if status in (403, 404):
        return None
    if status != 200 or not isinstance(payload, dict):
        raise GitHubError(f"couldn't read {full_name} (HTTP {status})", kind="http")
    return Repository(
        full_name=str(payload.get("full_name", full_name)),
        private=bool(payload.get("private")),
        html_url=str(payload.get("html_url", "")),
    )
