from __future__ import annotations

import pytest

from huske_mcp.cli import _redact_remote
from huske_mcp.config import Settings


def test_service_refuses_missing_or_short_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_MCP_REPOSITORY", "git@example.invalid:private/repo.git")
    monkeypatch.delenv("HUSKE_MCP_TOKEN", raising=False)
    with pytest.raises(ValueError, match="TOKEN"):
        Settings.from_env()

    monkeypatch.setenv("HUSKE_MCP_TOKEN", "short")
    with pytest.raises(ValueError, match="32"):
        Settings.from_env()


def test_doctor_remote_redacts_https_userinfo() -> None:
    assert (
        _redact_remote("https://secret-token@github.com/example/private.git")
        == "https://github.com/example/private.git"
    )


def test_service_refuses_git_option_injection(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_MCP_REPOSITORY", "--upload-pack=malicious")
    monkeypatch.setenv("HUSKE_MCP_TOKEN", "test-token-that-is-at-least-32-chars")
    with pytest.raises(ValueError, match="safe Git repository"):
        Settings.from_env()
