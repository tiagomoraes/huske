"""`huske sync login|logout|status|repos|use` against a fake GitHub.

The token store is in memory and the config is a temp file, so these tests
touch neither the Keychain nor the user's configuration.
"""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

import pytest

from huske.sync import account, github
from huske.sync import credentials as creds
from huske.sync.credentials import MemoryTokenStore
from huske.sync.github import DeviceCode, GitHubError, Installation, Repository, TokenSet

FAR = 4_000_000_000.0  # far-future expiry


@pytest.fixture
def store(monkeypatch: pytest.MonkeyPatch) -> MemoryTokenStore:
    memory = MemoryTokenStore()
    monkeypatch.setattr(creds, "default_token_store", lambda: memory)
    return memory


@pytest.fixture
def config(tmp_path: Path) -> Path:
    path = tmp_path / "config.toml"
    path.write_text(
        f'sync_root = "{tmp_path / "sync"}"\noutput_root = "{tmp_path / "transcripts"}"\n',
        encoding="utf-8",
    )
    return path


def _events(text: str) -> list[dict[str, object]]:
    return [json.loads(line) for line in text.splitlines() if line.startswith("{")]


def _connected(store: MemoryTokenStore) -> None:
    store.tokens = TokenSet("ghu_t", FAR, "ghr_t", FAR, login="octo")


def test_login_streams_the_code_then_saves_the_sign_in(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    code = DeviceCode("dev", "WDJB-MJHT", "https://github.com/login/device", 900, 5)
    monkeypatch.setattr(github, "start_device_flow", lambda: code)
    monkeypatch.setattr(
        github, "wait_for_authorization", lambda c, sleep: TokenSet("ghu_t", FAR, "ghr_t", FAR)
    )
    monkeypatch.setattr(github, "fetch_login", lambda token: "octo")

    assert account.run_login(config, json_output=True) == 0
    events = _events(capsys.readouterr().out)
    assert [event["event"] for event in events] == ["code", "connected"]
    assert events[0]["user_code"] == "WDJB-MJHT"
    assert events[1]["login"] == "octo"
    assert store.tokens is not None and store.tokens.login == "octo"
    assert "ghu_t" not in json.dumps(events)


def test_login_cancelled_on_github(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    code = DeviceCode("dev", "WDJB-MJHT", "https://github.com/login/device", 900, 5)
    monkeypatch.setattr(github, "start_device_flow", lambda: code)

    def denied(c: DeviceCode, sleep: object) -> TokenSet:
        raise GitHubError("sign-in was cancelled on GitHub", kind="denied")

    monkeypatch.setattr(github, "wait_for_authorization", denied)
    assert account.run_login(config, json_output=True) == 1
    assert _events(capsys.readouterr().out)[-1]["event"] == "error"
    assert store.tokens is None


def test_use_accepts_a_private_shared_repository(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _connected(store)
    monkeypatch.setattr(
        github,
        "fetch_repository",
        lambda token, name: Repository(name, private=True, html_url=""),
    )
    assert account.run_use("octo/huske-transcripts", config, json_output=True) == 0
    written = tomllib.loads(config.read_text())
    assert written["sync_auth"] == "github-app"
    assert written["sync_remote"] == "https://github.com/octo/huske-transcripts.git"
    assert _events(capsys.readouterr().out)[-1]["repository"] == "octo/huske-transcripts"


def test_use_refuses_a_public_repository(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _connected(store)
    monkeypatch.setattr(
        github, "fetch_repository", lambda token, name: Repository(name, private=False, html_url="")
    )
    assert account.run_use("octo/oops", config, json_output=True) == 1
    assert "is public" in str(_events(capsys.readouterr().out)[-1]["message"])
    assert "sync_auth" not in config.read_text()


def test_use_refuses_a_repository_not_shared_with_the_app(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _connected(store)
    monkeypatch.setattr(github, "fetch_repository", lambda token, name: None)
    assert account.run_use("octo/elsewhere", config, json_output=True) == 1
    event = _events(capsys.readouterr().out)[-1]
    assert "isn't shared with Huske Sync" in str(event["message"])
    assert event["install_url"] == github.install_url()


def test_use_without_a_sign_in_asks_to_reconnect(
    store: MemoryTokenStore, config: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert account.run_use("octo/huske-transcripts", config, json_output=True) == 1
    event = _events(capsys.readouterr().out)[-1]
    assert event["reconnect"] is True


def test_repos_reports_selection_and_repositories(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _connected(store)
    monkeypatch.setattr(
        github,
        "fetch_installation",
        lambda token: Installation(
            installed=True,
            installation_id=42,
            repository_selection="all",
            repositories=(Repository("octo/huske-transcripts", True, "u"),),
        ),
    )
    assert account.run_repos(config, json_output=True) == 0
    event = _events(capsys.readouterr().out)[-1]
    assert event["repository_selection"] == "all"
    assert event["installation_settings_url"] == "https://github.com/settings/installations/42"
    assert event["repositories"] == [
        {"full_name": "octo/huske-transcripts", "private": True, "html_url": "u"}
    ]


def test_status_is_local_and_reports_the_connection(
    store: MemoryTokenStore, config: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert account.run_status(config, json_output=True) == 0
    assert _events(capsys.readouterr().out)[-1]["connected"] is False

    _connected(store)
    config.write_text(
        config.read_text()
        + 'sync_auth = "github-app"\nsync_remote = "https://github.com/octo/t.git"\n'
    )
    assert account.run_status(config, json_output=True) == 0
    event = _events(capsys.readouterr().out)[-1]
    assert event["connected"] is True
    assert event["login"] == "octo"
    assert event["repository"] == "octo/t"
    assert "ghu_t" not in json.dumps(event)


def test_logout_forgets_the_sign_in_and_stops_automatic_sync(
    store: MemoryTokenStore, config: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _connected(store)
    config.write_text(
        config.read_text()
        + 'sync_auth = "github-app"\nsync_enabled = true\n'
        + 'sync_remote = "https://github.com/octo/t.git"\n'
    )
    assert account.run_logout(config, json_output=True) == 0
    assert store.tokens is None
    written = tomllib.loads(config.read_text())
    assert written["sync_enabled"] is False
    assert "sync_auth" not in written
    assert written["sync_remote"] == "https://github.com/octo/t.git"


def test_login_keeps_the_sign_in_when_the_account_lookup_flakes(
    monkeypatch: pytest.MonkeyPatch,
    store: MemoryTokenStore,
    config: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    code = DeviceCode("dev", "WDJB-MJHT", "https://github.com/login/device", 900, 5)
    monkeypatch.setattr(github, "start_device_flow", lambda: code)
    monkeypatch.setattr(
        github, "wait_for_authorization", lambda c, sleep: TokenSet("ghu_t", FAR, "ghr_t", FAR)
    )
    attempts = {"n": 0}

    def flaky_login(token: str) -> str:
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise GitHubError("timed out", kind="network", retryable=True)
        return "octo"

    monkeypatch.setattr(github, "fetch_login", flaky_login)
    assert account.run_login(config, json_output=True, sleep=lambda s: None) == 0
    assert store.tokens is not None and store.tokens.login == "octo"
    assert _events(capsys.readouterr().out)[-1]["event"] == "connected"
