"""Huske Sync GitHub App client: device flow, refresh, REST, remotes.

All HTTP goes through a fake transport; nothing here touches the network.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator

import pytest

from huske.sync import github
from huske.sync.github import DeviceCode, GitHubError, TokenSet


class FakeGitHub:
    """Scripted responses keyed by URL path; records every request."""

    def __init__(self, routes: dict[str, list[tuple[int, object]]]) -> None:
        self.routes = {path: iter(responses) for path, responses in routes.items()}
        self.requests: list[tuple[str, dict[str, str]]] = []

    def __call__(self, request: urllib.request.Request) -> tuple[int, bytes]:
        url = urllib.parse.urlsplit(request.full_url)
        key = url.path + (f"?{url.query}" if url.query else "")
        body = request.data.decode() if isinstance(request.data, bytes) else ""
        self.requests.append((key, dict(urllib.parse.parse_qsl(body))))
        responses: Iterator[tuple[int, object]] = self.routes[key]
        status, payload = next(responses)
        return status, json.dumps(payload).encode()


def _install(monkeypatch: pytest.MonkeyPatch, routes: dict[str, list[tuple[int, object]]]) -> FakeGitHub:
    fake = FakeGitHub(routes)
    monkeypatch.setattr(github, "transport", fake)
    return fake


def _code() -> DeviceCode:
    return DeviceCode(
        device_code="dev-123",
        user_code="WDJB-MJHT",
        verification_uri="https://github.com/login/device",
        expires_in=900,
        interval=5,
    )


class Clock:
    def __init__(self) -> None:
        self.now = 1_000_000.0
        self.sleeps: list[float] = []

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def __call__(self) -> float:
        return self.now


def test_device_flow_waits_slows_down_and_returns_tokens(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _install(
        monkeypatch,
        {
            "/login/oauth/access_token": [
                (200, {"error": "authorization_pending"}),
                (200, {"error": "slow_down", "interval": 10}),
                (
                    200,
                    {
                        "access_token": "ghu_secret",
                        "expires_in": 28800,
                        "refresh_token": "ghr_secret",
                        "refresh_token_expires_in": 15638400,
                        "token_type": "bearer",
                    },
                ),
            ]
        },
    )
    clock = Clock()
    tokens = github.wait_for_authorization(_code(), sleep=clock.sleep, clock=clock)

    assert clock.sleeps == [5, 5, 10]
    assert tokens.access_token == "ghu_secret"
    assert tokens.refresh_token == "ghr_secret"
    assert tokens.access_expires_at == pytest.approx(clock.now + 28800)
    # Public client: no secret is ever sent.
    assert all("client_secret" not in fields for _, fields in fake.requests)
    assert fake.requests[0][1]["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"


@pytest.mark.parametrize(
    ("error", "kind"),
    [("access_denied", "denied"), ("expired_token", "expired"), ("unsupported_grant_type", "http")],
)
def test_device_flow_failures_are_named(
    monkeypatch: pytest.MonkeyPatch, error: str, kind: str
) -> None:
    _install(monkeypatch, {"/login/oauth/access_token": [(200, {"error": error})]})
    clock = Clock()
    with pytest.raises(GitHubError) as excinfo:
        github.wait_for_authorization(_code(), sleep=clock.sleep, clock=clock)
    assert excinfo.value.kind == kind
    assert not excinfo.value.retryable


def test_device_flow_disabled_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    _install(monkeypatch, {"/login/device/code": [(400, {"error": "device_flow_disabled"})]})
    with pytest.raises(GitHubError, match="device sign-in turned off"):
        github.start_device_flow()


def test_refresh_rotates_without_a_secret(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _install(
        monkeypatch,
        {
            "/login/oauth/access_token": [
                (200, {"access_token": "ghu_new", "expires_in": 28800, "refresh_token": "ghr_new"}),
            ]
        },
    )
    old = TokenSet("ghu_old", 0.0, "ghr_old", None, login="octo")
    renewed = github.refresh(old, clock=lambda: 100.0)
    assert renewed.access_token == "ghu_new"
    assert renewed.refresh_token == "ghr_new"
    assert renewed.login == "octo"
    fields = fake.requests[0][1]
    assert fields == {
        "client_id": github.client_id(),
        "grant_type": "refresh_token",
        "refresh_token": "ghr_old",
    }


def test_refused_refresh_means_reconnect(monkeypatch: pytest.MonkeyPatch) -> None:
    # A reused refresh token comes back as incorrect_client_credentials.
    _install(
        monkeypatch,
        {"/login/oauth/access_token": [(200, {"error": "incorrect_client_credentials"})]},
    )
    with pytest.raises(GitHubError) as excinfo:
        github.refresh(TokenSet("a", 0.0, "r", None))
    assert excinfo.value.kind == "revoked"
    assert "connect GitHub again" in str(excinfo.value)


def test_fetch_installation_filters_our_app_and_paginates(monkeypatch: pytest.MonkeyPatch) -> None:
    page_one = [
        {"full_name": f"octo/repo-{i:03d}", "private": True, "html_url": "u"} for i in range(100)
    ]
    _install(
        monkeypatch,
        {
            "/user/installations?per_page=100": [
                (
                    200,
                    {
                        "installations": [
                            {"id": 1, "app_slug": "someone-else"},
                            {"id": 42, "app_slug": "huske-sync", "repository_selection": "all"},
                        ]
                    },
                )
            ],
            "/user/installations/42/repositories?per_page=100&page=1": [
                (200, {"repositories": page_one})
            ],
            "/user/installations/42/repositories?per_page=100&page=2": [
                (200, {"repositories": [{"full_name": "octo/transcripts", "private": True}]})
            ],
        },
    )
    installation = github.fetch_installation("ghu_token")
    assert installation.installed
    assert installation.installation_id == 42
    assert installation.repository_selection == "all"
    assert len(installation.repositories) == 101


def test_no_installation_yet(monkeypatch: pytest.MonkeyPatch) -> None:
    _install(monkeypatch, {"/user/installations?per_page=100": [(200, {"installations": []})]})
    assert github.fetch_installation("t") == github.Installation(installed=False)


def test_repository_not_shared_is_none_and_revoked_token_raises(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _install(
        monkeypatch,
        {
            "/repos/octo/hidden": [(404, {"message": "Not Found"})],
            "/repos/octo/any": [(401, {"message": "Bad credentials"})],
        },
    )
    assert github.fetch_repository("t", "octo/hidden") is None
    with pytest.raises(GitHubError) as excinfo:
        github.fetch_repository("t", "octo/any")
    assert excinfo.value.kind == "revoked"


def test_network_failure_is_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def offline(request: urllib.request.Request) -> tuple[int, bytes]:
        return github._urllib_transport(request)

    def raise_urlerror(*args: object, **kwargs: object) -> object:
        raise urllib.error.URLError("nodename nor servname provided")

    monkeypatch.setattr(urllib.request, "urlopen", raise_urlerror)
    monkeypatch.setattr(github, "transport", offline)
    with pytest.raises(GitHubError) as excinfo:
        github.start_device_flow()
    assert excinfo.value.kind == "network"
    assert excinfo.value.retryable


def test_token_set_never_prints_secrets_and_round_trips() -> None:
    tokens = TokenSet("ghu_secret", 10.0, "ghr_secret", 20.0, login="octo")
    assert "ghu_secret" not in repr(tokens)
    assert "ghr_secret" not in repr(tokens)
    assert TokenSet.from_json(tokens.to_json()) == tokens
    assert tokens.needs_refresh(now=9.0, margin=5.0)
    assert not tokens.needs_refresh(now=1.0, margin=5.0)
    assert tokens.can_refresh(now=19.0)
    assert not tokens.can_refresh(now=21.0)


@pytest.mark.parametrize(
    ("remote", "expected"),
    [
        ("https://github.com/octo/huske-transcripts.git", ("octo", "huske-transcripts")),
        ("https://github.com/octo/huske-transcripts", ("octo", "huske-transcripts")),
        ("https://github.com/octo/repo.name/", ("octo", "repo.name")),
        ("git@github.com:octo/repo.git", None),
        ("https://gitlab.com/octo/repo.git", None),
        ("https://token@github.com/octo/repo.git", None),
        ("https://github.com/octo/../x.git", None),
    ],
)
def test_parse_github_https_remote(remote: str, expected: tuple[str, str] | None) -> None:
    assert github.parse_github_https_remote(remote) == expected


def test_new_repository_url_is_private_and_prefilled() -> None:
    url = github.new_repository_url()
    query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
    assert query["visibility"] == "private"
    assert query["name"] == "huske-transcripts"


def test_forks_can_point_at_their_own_app(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_GITHUB_APP_CLIENT_ID", "Iv-fork")
    monkeypatch.setenv("HUSKE_GITHUB_APP_SLUG", "fork-sync")
    assert github.client_id() == "Iv-fork"
    assert github.install_url() == "https://github.com/apps/fork-sync/installations/new"


def test_device_flow_survives_a_dropped_poll(monkeypatch: pytest.MonkeyPatch) -> None:
    """One timed-out poll must not cancel a sign-in the user is completing."""
    calls = {"n": 0}

    def flaky(request: urllib.request.Request) -> tuple[int, bytes]:
        calls["n"] += 1
        if calls["n"] == 1:
            raise GitHubError("timed out", kind="network", retryable=True)
        if calls["n"] == 2:
            return 502, b"{}"
        return 200, json.dumps({"access_token": "ghu_ok", "expires_in": 60}).encode()

    monkeypatch.setattr(github, "transport", flaky)
    clock = Clock()
    tokens = github.wait_for_authorization(_code(), sleep=clock.sleep, clock=clock)
    assert tokens.access_token == "ghu_ok"
    assert calls["n"] == 3
