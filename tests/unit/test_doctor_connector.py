"""``huske doctor`` reports connector mode — and stays silent when it's off."""

from __future__ import annotations

import pytest

from huske.config import RuntimeConfig
from huske.doctor import _connector_checks

RESOURCE = "https://huske.example.com/mcp"


def test_silent_when_connector_mode_is_off() -> None:
    assert _connector_checks(RuntimeConfig()) == []


def test_reports_a_missing_passphrase_as_a_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    """Not a warning: this is one of the two ways to publish an open archive."""
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: None)
    checks = _connector_checks(RuntimeConfig(mcp_public_url=RESOURCE))
    by_name = {c.name: c for c in checks}
    assert by_name["connector passphrase"].ok is False
    assert "set-password" in (by_name["connector passphrase"].hint or "")


def test_passes_when_configured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: "scrypt$x")
    checks = _connector_checks(RuntimeConfig(mcp_public_url=RESOURCE))
    assert all(c.ok for c in checks)
    assert any(c.detail == RESOURCE for c in checks)


def test_flags_plaintext_http(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: "scrypt$x")
    checks = _connector_checks(RuntimeConfig(mcp_public_url="http://huske.example.com/mcp"))
    url_check = next(c for c in checks if c.name == "connector url")
    assert url_check.ok is False
    assert "clear" in (url_check.hint or "")


def test_flags_a_relative_url(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: "scrypt$x")
    checks = _connector_checks(RuntimeConfig(mcp_public_url="huske.example.com/mcp"))
    assert len(checks) == 1
    assert checks[0].ok is False
