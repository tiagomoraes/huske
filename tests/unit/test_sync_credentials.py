"""Huske Sync sign-in storage and how Git receives the token."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

from huske.sync.credentials import (
    CredentialError,
    GitHubAppCredentials,
    KeychainTokenStore,
    MemoryTokenStore,
    token_git_env,
)
from huske.sync.github import GitHubError, TokenSet

NOW = 1_000_000.0


def _tokens(expires_in: float = 3600, refresh_in: float | None = 86400) -> TokenSet:
    return TokenSet(
        access_token="ghu_current",
        access_expires_at=NOW + expires_in,
        refresh_token="ghr_current",
        refresh_expires_at=None if refresh_in is None else NOW + refresh_in,
        login="octo",
    )


def test_not_connected_is_a_permanent_error() -> None:
    provider = GitHubAppCredentials(MemoryTokenStore(), clock=lambda: NOW)
    with pytest.raises(CredentialError, match="Connect GitHub") as excinfo:
        provider.git_env()
    assert not excinfo.value.retryable


def test_fresh_token_is_used_as_is() -> None:
    def refresher(tokens: TokenSet) -> TokenSet:
        raise AssertionError("no refresh expected")

    provider = GitHubAppCredentials(MemoryTokenStore(_tokens()), clock=lambda: NOW, refresher=refresher)
    env = provider.git_env()
    assert env["HUSKE_GIT_TOKEN"] == "ghu_current"
    assert env["HUSKE_GIT_USERNAME"] == "octo"


def test_token_near_expiry_is_renewed_and_saved() -> None:
    store = MemoryTokenStore(_tokens(expires_in=60))
    renewed = TokenSet("ghu_next", NOW + 28800, "ghr_next", NOW + 86400, login="octo")
    provider = GitHubAppCredentials(store, clock=lambda: NOW, refresher=lambda _: renewed)
    assert provider.git_env()["HUSKE_GIT_TOKEN"] == "ghu_next"
    assert store.tokens == renewed


def test_expired_renewal_asks_to_reconnect() -> None:
    store = MemoryTokenStore(_tokens(expires_in=-10, refresh_in=-5))
    provider = GitHubAppCredentials(store, clock=lambda: NOW)
    with pytest.raises(CredentialError, match="expired") as excinfo:
        provider.git_env()
    assert not excinfo.value.retryable


def test_offline_renewal_is_retryable() -> None:
    def offline(_: TokenSet) -> TokenSet:
        raise GitHubError("offline", kind="network", retryable=True)

    provider = GitHubAppCredentials(
        MemoryTokenStore(_tokens(expires_in=60)), clock=lambda: NOW, refresher=offline
    )
    with pytest.raises(CredentialError) as excinfo:
        provider.git_env()
    assert excinfo.value.retryable


def test_git_gets_only_our_token_even_with_other_helpers_configured(tmp_path: Path) -> None:
    """A Mac with osxkeychain and `gh auth setup-git` helpers configured must
    neither consult them nor hand them the token."""
    home = tmp_path / "home"
    home.mkdir()
    marker = tmp_path / "other-helper-ran"
    other = f"!f() {{ touch {marker}; echo username=other; echo password=other-secret; }}; f"
    (home / ".gitconfig").write_text(
        "[credential]\n"
        f"\thelper = \"{other}\"\n"
        '[credential "https://github.com"]\n'
        f"\thelper = \"{other}\"\n",
        encoding="utf-8",
    )
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": str(home),
        "GIT_CONFIG_NOSYSTEM": "1",
        **token_git_env("ghu_scoped", "octo"),
    }
    for action in ("fill", "approve"):
        result = subprocess.run(
            ["git", "credential", action],
            input="protocol=https\nhost=github.com\npath=octo/transcripts.git\n"
            + ("username=octo\npassword=ghu_scoped\n" if action == "approve" else "")
            + "\n",
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )
        if action == "fill":
            assert "password=ghu_scoped" in result.stdout
            assert "username=octo" in result.stdout
    assert not marker.exists()
    assert "ghu_scoped" not in (home / ".gitconfig").read_text()


@pytest.fixture
def temp_keychain(tmp_path: Path) -> Iterator[Path]:
    if sys.platform != "darwin" or shutil.which("security") is None:
        pytest.skip("macOS Keychain only")
    keychain = tmp_path / "huske-test.keychain-db"
    subprocess.run(["security", "create-keychain", "-p", "pw", str(keychain)], check=True)
    subprocess.run(["security", "unlock-keychain", "-p", "pw", str(keychain)], check=True)
    try:
        yield keychain
    finally:
        subprocess.run(["security", "delete-keychain", str(keychain)], check=False)


def test_keychain_store_round_trip(temp_keychain: Path) -> None:
    store = KeychainTokenStore(keychain=temp_keychain)
    assert store.load() is None

    first = _tokens()
    store.save(first)
    assert store.load() == first

    second = TokenSet("ghu_rotated", NOW + 1, "ghr_rotated", NOW + 2, login="octo")
    store.save(second)  # -U updates in place
    assert store.load() == second

    store.delete()
    assert store.load() is None
    store.delete()  # deleting nothing is fine
