"""``huske connect``: the wiring each client needs, and whether it works today.

The value of this command is that it never says "ready" about a path that isn't,
so most of these tests assert on the *status*, not the prose.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.config import RuntimeConfig
from huske.connect import (
    CLIENT_KEYS,
    CLIENTS,
    Wiring,
    render_client,
    render_summary,
    resolve_wiring,
    run_connect,
)

CONNECTOR = "https://huske.example.com/mcp"


def _wiring(*, connector: str | None = None, password: bool = False, token: str | None = "tok") -> Wiring:
    return Wiring(
        loopback_url="http://127.0.0.1:7641/mcp",
        connector_url=connector,
        token=token,
        has_password=password,
        token_path="/home/u/.config/huske/mcp_token",
    )


def _client(key: str):  # type: ignore[no-untyped-def]
    return next(c for c in CLIENTS if c.key == key)


# --- resolve_wiring ---------------------------------------------------------


def test_resolve_wiring_reads_config_and_disk(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    token_file = tmp_path / "mcp_token"
    token_file.write_text("secret-token\n", encoding="utf-8")
    monkeypatch.setattr("huske.mcp.token.default_token_path", lambda: token_file)
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: "scrypt$...")

    cfg = RuntimeConfig(mcp_public_url=CONNECTOR, mcp_port=7999)
    wiring = resolve_wiring(cfg)
    assert wiring.token == "secret-token"
    assert wiring.loopback_url == "http://127.0.0.1:7999/mcp"
    assert wiring.connector_url == CONNECTOR
    assert wiring.connector_ready is True


def test_resolve_wiring_never_creates_a_token(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Asking a question must not mint a credential."""
    token_file = tmp_path / "mcp_token"
    monkeypatch.setattr("huske.mcp.token.default_token_path", lambda: token_file)
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: None)

    wiring = resolve_wiring(RuntimeConfig())
    assert wiring.token is None
    assert not token_file.exists()


def test_connector_not_ready_without_a_passphrase() -> None:
    assert _wiring(connector=CONNECTOR, password=False).connector_ready is False
    assert _wiring(connector=CONNECTOR, password=True).connector_ready is True


def test_trailing_slash_is_trimmed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.mcp.token.default_token_path", lambda: Path("/nonexistent"))
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: None)
    cfg = RuntimeConfig(mcp_public_url=CONNECTOR + "/")
    assert resolve_wiring(cfg).connector_url == CONNECTOR


# --- the summary ------------------------------------------------------------


def test_summary_lists_every_client() -> None:
    text = render_summary(_wiring())
    for client in CLIENTS:
        assert client.label in text


def test_summary_flags_remote_clients_as_blocked_without_connector_mode() -> None:
    text = render_summary(_wiring())
    assert "off — set `mcp_public_url`" in text
    # Both phone/web clients must be reported as unusable, not merely undocumented.
    for line in text.splitlines():
        if "Claude on iPhone" in line or "ChatGPT" in line:
            assert "needs connector mode" in line


def test_summary_marks_remote_clients_ready_once_connector_mode_is_up() -> None:
    text = render_summary(_wiring(connector=CONNECTOR, password=True))
    assert CONNECTOR in text
    assert "(ready)" in text
    for line in text.splitlines():
        if "Claude on iPhone" in line or "ChatGPT (app" in line:
            assert "needs connector mode" not in line


def test_summary_calls_out_a_missing_passphrase() -> None:
    assert "no passphrase set" in render_summary(_wiring(connector=CONNECTOR, password=False))


def test_summary_tells_you_to_run_the_daemon_when_no_token_exists() -> None:
    text = render_summary(_wiring(token=None))
    assert "run `huske mcp` once" in text


# --- per-client output ------------------------------------------------------


def test_claude_code_gets_the_loopback_command() -> None:
    text = render_client(_client("claude-code"), _wiring())
    assert "claude mcp add --transport http huske http://127.0.0.1:7641/mcp" in text
    assert "Bearer tok" in text


def test_claude_code_gains_a_remote_form_in_connector_mode() -> None:
    text = render_client(_client("claude-code"), _wiring(connector=CONNECTOR, password=True))
    assert CONNECTOR in text
    assert "opens a browser once" in text


def test_remote_clients_explain_how_to_unblock_themselves() -> None:
    for key in ("claude-app", "chatgpt"):
        text = render_client(_client(key), _wiring())
        assert "huske mcp set-password" in text
        assert "mcp_public_url" in text


def test_remote_clients_print_the_url_once_ready() -> None:
    for key in ("claude-app", "chatgpt"):
        text = render_client(_client(key), _wiring(connector=CONNECTOR, password=True))
        assert CONNECTOR in text


def test_chatgpt_mentions_developer_mode() -> None:
    text = render_client(_client("chatgpt"), _wiring(connector=CONNECTOR, password=True))
    assert "Developer mode" in text


def test_claude_desktop_documents_the_no_space_header_quirk() -> None:
    text = render_client(_client("claude-desktop"), _wiring())
    assert "mcp-remote" in text
    assert "no space" in text


def test_hermes_stays_on_loopback() -> None:
    text = render_client(_client("hermes"), _wiring(connector=CONNECTOR, password=True))
    assert "127.0.0.1:7641" in text
    assert "no OAuth" in text


def test_local_clients_warn_when_no_token_exists() -> None:
    text = render_client(_client("codex"), _wiring(token=None))
    assert "No token yet" in text
    assert "<token from the `huske mcp` banner>" in text


def test_every_client_key_renders() -> None:
    for key in CLIENT_KEYS:
        assert render_client(_client(key), _wiring(connector=CONNECTOR, password=True))


# --- the command ------------------------------------------------------------


@pytest.fixture(autouse=True)
def _quiet(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)


def test_run_connect_summary_exits_zero(capsys: pytest.CaptureFixture[str]) -> None:
    assert run_connect(None, config_path=Path("/nonexistent.toml")) == 0
    assert "huske → your LLMs" in capsys.readouterr().out


def test_run_connect_unknown_client_is_an_error(capsys: pytest.CaptureFixture[str]) -> None:
    assert run_connect("gemini", config_path=Path("/nonexistent.toml")) == 2
    assert "unknown client" in capsys.readouterr().out


@pytest.mark.parametrize(
    ("alias", "expected"),
    [
        ("claude", "Claude on iPhone / web"),
        ("claude-ios", "Claude on iPhone / web"),
        ("cowork", "Claude Desktop / Cowork"),
        ("gpt", "ChatGPT (app / web)"),
        ("vps", "Co-located agent on the server"),
        ("CLAUDE-CODE", "Claude Code"),
    ],
)
def test_aliases_resolve(alias: str, expected: str, capsys: pytest.CaptureFixture[str]) -> None:
    assert run_connect(alias, config_path=Path("/nonexistent.toml")) == 0
    assert expected in capsys.readouterr().out


def test_cli_connect_command_works() -> None:
    result = CliRunner().invoke(app, ["connect", "--config", "/nonexistent.toml"])
    assert result.exit_code == 0
    assert "loopback" in result.stdout


def test_cli_connect_one_client() -> None:
    result = CliRunner().invoke(
        app, ["connect", "chatgpt", "--config", "/nonexistent.toml"]
    )
    assert result.exit_code == 0
    assert "ChatGPT" in result.stdout


def test_cli_mcp_status_reports_connector_off(tmp_path: Path) -> None:
    cfg = tmp_path / "config.toml"
    cfg.write_text("mcp_port = 7641\n", encoding="utf-8")
    result = CliRunner().invoke(app, ["mcp", "status", "--config", str(cfg)])
    assert result.exit_code == 0
    assert "connector  off" in result.stdout
