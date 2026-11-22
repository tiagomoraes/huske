"""Where the Huske Sync sign-in lives, and how Git gets it.

The token set is stored in the user's macOS login Keychain through
``/usr/bin/security``. The secret is written over ``security -i``'s standard
input, never as a process argument, so other processes can't read it from the
process table. Items created by ``security`` are readable by ``security``
without a Keychain prompt, which is what lets the headless engine (launchd)
use them.

Git receives the token only through the environment of the command that needs
it: a one-shot credential helper reads it from a variable, and every helper
configured on the Mac (osxkeychain, ``gh``) is reset for that command so the
token is never stored anywhere else.
"""

from __future__ import annotations

import base64
import os
import subprocess
import time
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from huske.sync import github
from huske.sync.github import GitHubError, TokenSet

#: Refresh when less than this much lifetime remains. Generous on purpose: a
#: refresh invalidates the previous access token immediately.
REFRESH_MARGIN_SECONDS = 15 * 60

KEYCHAIN_SERVICE = "Huske Sync GitHub sign-in"
KEYCHAIN_ACCOUNT = "github-app"
_SECURITY = "/usr/bin/security"
_NOT_FOUND = 44  # errSecItemNotFound, as security(1) reports it


class CredentialError(RuntimeError):
    def __init__(self, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


class TokenStore(Protocol):
    def load(self) -> TokenSet | None: ...

    def save(self, tokens: TokenSet) -> None: ...

    def delete(self) -> None: ...


class MemoryTokenStore:
    """In-process store for tests and dry runs."""

    def __init__(self, tokens: TokenSet | None = None) -> None:
        self.tokens = tokens

    def load(self) -> TokenSet | None:
        return self.tokens

    def save(self, tokens: TokenSet) -> None:
        self.tokens = tokens

    def delete(self) -> None:
        self.tokens = None


class KeychainTokenStore:
    """The token set as one generic password item in a macOS keychain."""

    def __init__(self, keychain: Path | None = None) -> None:
        # ``None`` means the user's default (login) keychain; tests pass a
        # throwaway keychain file.
        self.keychain = keychain

    def _keychain_args(self) -> list[str]:
        return [str(self.keychain)] if self.keychain else []

    def load(self) -> TokenSet | None:
        result = self._security(
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
            *self._keychain_args(),
        )
        if result.returncode == _NOT_FOUND:
            return None
        if result.returncode != 0:
            raise CredentialError(
                "couldn't read the GitHub sign-in from the Keychain "
                f"({result.stderr.strip() or result.returncode}); is the Mac unlocked?",
                retryable=True,
            )
        try:
            return TokenSet.from_json(base64.b64decode(result.stdout.strip()).decode())
        except (ValueError, KeyError) as exc:
            raise CredentialError(
                "the GitHub sign-in in the Keychain is unreadable — connect GitHub again"
            ) from exc

    def save(self, tokens: TokenSet) -> None:
        secret = base64.b64encode(tokens.to_json().encode()).decode()
        target = f' "{self.keychain}"' if self.keychain else ""
        command = (
            f'add-generic-password -U -s "{KEYCHAIN_SERVICE}" -a "{KEYCHAIN_ACCOUNT}" '
            f'-l "{KEYCHAIN_SERVICE}" -w {secret}{target}\n'
        )
        # ``security -i`` reads the command (and so the secret) from stdin.
        result = self._security("-i", stdin=command)
        stored = self.load()
        if stored is None or stored.access_token != tokens.access_token:
            raise CredentialError(
                "couldn't save the GitHub sign-in to the Keychain "
                f"({result.stderr.strip() or 'not stored'})"
            )

    def delete(self) -> None:
        result = self._security(
            "delete-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            *self._keychain_args(),
        )
        if result.returncode not in (0, _NOT_FOUND):
            raise CredentialError(
                f"couldn't remove the GitHub sign-in ({result.stderr.strip()})"
            )

    @staticmethod
    def _security(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [_SECURITY, *args],
                input=stdin,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise CredentialError(f"the Keychain is unavailable ({exc})", retryable=True) from exc


def default_token_store() -> TokenStore:
    """The login keychain — or, for development, ``HUSKE_SYNC_KEYCHAIN``.

    Pointing the variable at a throwaway keychain file lets the whole sign-in
    flow be exercised against GitHub without touching the login keychain.
    """
    override = os.environ.get("HUSKE_SYNC_KEYCHAIN")
    return KeychainTokenStore(Path(override) if override else None)


def token_git_env(token: str, username: str) -> dict[str, str]:
    """Environment that makes Git authenticate with ``token`` and nothing else.

    ``GIT_CONFIG_*`` entries apply after every config file. The empty values
    clear all previously configured helpers — generic and github.com-specific
    ones such as ``gh auth setup-git`` writes — so neither the Mac's Keychain
    helper nor ``gh`` sees the token or answers instead of it.
    """
    helper = (
        '!f() { test "$1" = get || return 0; '
        'echo "username=$HUSKE_GIT_USERNAME"; echo "password=$HUSKE_GIT_TOKEN"; }; f'
    )
    return {
        "HUSKE_GIT_TOKEN": token,
        "HUSKE_GIT_USERNAME": username or "x-access-token",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_COUNT": "3",
        "GIT_CONFIG_KEY_0": "credential.helper",
        "GIT_CONFIG_VALUE_0": "",
        "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
        "GIT_CONFIG_VALUE_1": "",
        "GIT_CONFIG_KEY_2": "credential.helper",
        "GIT_CONFIG_VALUE_2": helper,
    }


class GitHubAppCredentials:
    """Hands Git a fresh Huske Sync token. Call only under the sync lock.

    A refresh rotates both tokens and invalidates the old access token at
    once; holding the cross-process sync lock guarantees no other Huske process
    is mid-push with the token being replaced.
    """

    def __init__(
        self,
        store: TokenStore,
        *,
        clock: Callable[[], float] = time.time,
        refresher: Callable[[TokenSet], TokenSet] = github.refresh,
        margin: float = REFRESH_MARGIN_SECONDS,
    ) -> None:
        self.store = store
        self._clock = clock
        self._refresher = refresher
        self._margin = margin

    def fresh_tokens(self) -> TokenSet:
        tokens = self.store.load()
        if tokens is None:
            raise CredentialError(
                "Huske isn't connected to GitHub — choose Connect GitHub in "
                "Huske → Cloud sync"
            )
        now = self._clock()
        if not tokens.needs_refresh(now, self._margin):
            return tokens
        if not tokens.can_refresh(now):
            raise CredentialError(
                "the GitHub sign-in expired — choose Connect GitHub in Huske → Cloud sync"
            )
        try:
            renewed = self._refresher(tokens)
        except GitHubError as exc:
            raise CredentialError(str(exc), retryable=exc.retryable) from exc
        self.store.save(renewed)
        return renewed

    def git_env(self) -> dict[str, str]:
        tokens = self.fresh_tokens()
        return token_git_env(tokens.access_token, tokens.login)
