"""API keys in the macOS Keychain, through /usr/bin/security.

Unit tests fake the subprocess; one test drives the real ``security`` tool
against a throwaway keychain file so the user's login keychain is never
touched.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

from huske.distill import keychain
from huske.distill.keychain import KeychainError


class _FakeSecurity:
    def __init__(self) -> None:
        self.items: dict[str, str] = {}
        self.calls: list[tuple[list[str], str | None]] = []

    def __call__(self, args: list[str], *, input: str | None = None, **_: Any) -> Any:
        self.calls.append((args, input))
        out, code = "", 0
        if args[1:2] == ["-i"]:
            assert input is not None
            # add-generic-password -U -s "svc" -a "acct" -l "label" -w "secret"
            parts = input.split('"')
            account, secret = parts[3], parts[7]
            self.items[account] = secret
        elif args[1] == "find-generic-password":
            account = args[args.index("-a") + 1]
            if account not in self.items:
                code = 44
            elif "-w" in args:
                out = self.items[account] + "\n"
        elif args[1] == "delete-generic-password":
            account = args[args.index("-a") + 1]
            code = 0 if self.items.pop(account, None) is not None else 44
        return subprocess.CompletedProcess(args, code, stdout=out, stderr="")


@pytest.fixture()
def fake(monkeypatch: pytest.MonkeyPatch) -> _FakeSecurity:
    fake = _FakeSecurity()
    monkeypatch.setattr(keychain, "_run", fake)
    monkeypatch.setattr(keychain, "_security_path", lambda: "/usr/bin/security")
    monkeypatch.delenv("HUSKE_KEYCHAIN", raising=False)
    return fake


def test_set_get_delete_round_trip(fake: _FakeSecurity) -> None:
    assert keychain.get_key("openai") is None
    assert keychain.has_key("openai") is False
    keychain.set_key("openai", "sk-test_ABC-123")
    assert keychain.get_key("openai") == "sk-test_ABC-123"
    assert keychain.has_key("openai") is True
    assert keychain.delete_key("openai") is True
    assert keychain.delete_key("openai") is False


def test_secret_never_appears_on_a_command_line(fake: _FakeSecurity) -> None:
    keychain.set_key("anthropic", "sk-ant-secret-value")
    for args, stdin in fake.calls:
        assert not any("sk-ant-secret-value" in a for a in args)
        if args[1:2] == ["-i"]:
            assert stdin is not None and "sk-ant-secret-value" in stdin


@pytest.mark.parametrize("bad", ["", "has space", 'quote"inside', "back\\slash", "new\nline", "é"])
def test_unusable_keys_are_rejected(fake: _FakeSecurity, bad: str) -> None:
    with pytest.raises(KeychainError):
        keychain.set_key("openai", bad)
    assert fake.calls == []


def test_unknown_provider_is_rejected(fake: _FakeSecurity) -> None:
    with pytest.raises(KeychainError):
        keychain.set_key("mlx", "sk-whatever")


def test_status_lists_providers_without_secrets(fake: _FakeSecurity) -> None:
    keychain.set_key("openrouter", "sk-or-v1-abc")
    status = keychain.key_status()
    assert status["openrouter"] is True
    assert status["openai"] is False
    assert "sk-or-v1-abc" not in repr(status)


def test_missing_security_tool_is_a_clear_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(keychain, "_security_path", lambda: None)
    with pytest.raises(KeychainError, match="macOS Keychain"):
        keychain.set_key("openai", "sk-abc-12345")
    assert keychain.get_key("openai") is None


def test_env_keychain_path_is_passed_through(
    fake: _FakeSecurity, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    path = tmp_path / "test.keychain-db"
    monkeypatch.setenv("HUSKE_KEYCHAIN", str(path))
    keychain.set_key("openai", "sk-abc-12345")
    keychain.get_key("openai")
    for args, stdin in fake.calls:
        if args[1:2] == ["-i"]:
            assert stdin is not None and str(path) in stdin
        else:
            assert args[-1] == str(path)


@pytest.mark.skipif(
    sys.platform != "darwin" or shutil.which("security") is None,
    reason="needs the macOS security tool",
)
def test_real_security_tool_with_a_throwaway_keychain(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "huske-test.keychain-db"
    subprocess.run(
        ["security", "create-keychain", "-p", "pw", str(path)], check=True, capture_output=True
    )
    try:
        subprocess.run(
            ["security", "unlock-keychain", "-p", "pw", str(path)],
            check=True,
            capture_output=True,
        )
        monkeypatch.setenv("HUSKE_KEYCHAIN", str(path))
        keychain.set_key("openai", "sk-test_real-123")
        assert keychain.get_key("openai") == "sk-test_real-123"
        keychain.set_key("openai", "sk-test_real-456")  # update in place
        assert keychain.get_key("openai") == "sk-test_real-456"
        assert keychain.has_key("openai")
        assert keychain.delete_key("openai")
        assert keychain.get_key("openai") is None
    finally:
        subprocess.run(["security", "delete-keychain", str(path)], capture_output=True)
