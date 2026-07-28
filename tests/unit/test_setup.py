"""``huske setup``: the guided local path.

The properties that matter are honesty ones — never claim ready when nothing can
answer, never clobber a config file that holds someone else's MCP servers, and
never advertise an `--apply` that doesn't do what it says.
"""

from __future__ import annotations

import json
import socket
from pathlib import Path

import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.config import RuntimeConfig
from huske.setup import (
    Report,
    Step,
    apply_claude_desktop,
    build_report,
    claude_desktop_entry,
    index_status,
    render,
    run_setup,
    server_running,
    upgrade_caveat,
    upgrade_command,
)

TRANSCRIPT = """---
session_id: 20260727T093000_ab12
chunk_seq: 1
start_time: 2026-07-27T09:30:00-03:00
end_time: 2026-07-27T09:31:00-03:00
language: pt
---

# 2026-07-27 09:30

[09:30:05 · mic] we agreed the pricing model stays flat
"""


@pytest.fixture
def cfg(tmp_path: Path) -> RuntimeConfig:
    day = tmp_path / "transcripts" / "2026-07-27"
    day.mkdir(parents=True)
    (day / "093000_ab12_001.md").write_text(TRANSCRIPT, encoding="utf-8")
    return RuntimeConfig(
        output_root=tmp_path / "transcripts",
        index_root=tmp_path / "index",
        mcp_port=_free_port(),
    )


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
    return port


def _steps(report: Report) -> dict[str, Step]:
    return {s.key: s for s in report.steps}


# --- upgrade command -------------------------------------------------------


@pytest.mark.parametrize(
    ("prefix", "expected"),
    [
        ("/Users/x/.local/share/uv/tools/huske", "uv tool install"),
        ("/Users/x/.local/pipx/venvs/huske", "pipx install"),
        ("/usr/local/lib/python3.13", "pip install"),
    ],
)
def test_upgrade_command_matches_the_install_layout(
    prefix: str, expected: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A wrong command appears to succeed and changes nothing — worst failure mode."""
    monkeypatch.setattr("sys.prefix", prefix)
    assert expected in upgrade_command()


def test_brew_is_never_told_to_reinstall(monkeypatch: pytest.MonkeyPatch) -> None:
    """The tap formula pins wheel resources and carries none of the search deps,
    so `brew reinstall` rebuilds the same venv without them — it would look like
    it worked. Verified against the live formula on 2026-07-28."""
    monkeypatch.setattr("sys.prefix", "/opt/homebrew/Cellar/huske/0.12.0/libexec")
    command = upgrade_command()
    assert "reinstall" not in command
    assert "-m pip install" in command
    assert "huske[mcp]" in command


def test_brew_route_states_that_an_upgrade_undoes_it(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("sys.prefix", "/opt/homebrew/Cellar/huske/0.12.0/libexec")
    caveat = upgrade_caveat()
    assert caveat is not None
    assert "brew upgrade" in caveat


def test_no_caveat_for_clean_install_routes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("sys.prefix", "/Users/x/.local/share/uv/tools/huske")
    assert upgrade_caveat() is None


def test_blocked_extra_step_carries_the_caveat(
    cfg: RuntimeConfig, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("huske.setup.extra_installed", lambda: False)
    monkeypatch.setattr("sys.prefix", "/opt/homebrew/Cellar/huske/0.12.0/libexec")
    step = _steps(build_report(cfg))["extra"]
    assert step.state == "blocked"
    assert "brew upgrade" in step.detail


# --- detection -------------------------------------------------------------


def test_index_status_missing(cfg: RuntimeConfig) -> None:
    assert index_status(cfg) == (False, 0)


def test_index_status_reads_without_the_extension(cfg: RuntimeConfig, tmp_path: Path) -> None:
    """Counting indexed files must not require loading sqlite-vec."""
    import sqlite3

    from huske.paths import index_db_path

    db = index_db_path(cfg)
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db)
    conn.execute("CREATE TABLE index_meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO index_meta VALUES ('dim', '64')")
    conn.execute(
        "CREATE TABLE indexed_files (path TEXT PRIMARY KEY, content_hash TEXT, "
        "model_id TEXT, passages INTEGER, indexed_at TEXT)"
    )
    conn.execute("INSERT INTO indexed_files VALUES ('/t/a', 'h', 'm', 3, 'now')")
    conn.commit()
    conn.close()
    assert index_status(cfg) == (True, 1)


def test_server_running_detects_a_listener(cfg: RuntimeConfig) -> None:
    assert server_running(cfg) is False
    listener = socket.socket()
    listener.bind((cfg.mcp_host, cfg.mcp_port))
    listener.listen(1)
    try:
        assert server_running(cfg) is True
    finally:
        listener.close()


# --- report ----------------------------------------------------------------


def test_report_flags_an_unindexed_corpus(cfg: RuntimeConfig) -> None:
    steps = _steps(build_report(cfg))
    assert steps["index"].state == "todo"
    assert "0 of 1" in steps["index"].detail
    assert steps["index"].fix == "huske index"


def test_report_says_record_something_first(tmp_path: Path) -> None:
    empty = RuntimeConfig(output_root=tmp_path / "none", index_root=tmp_path / "i")
    steps = _steps(build_report(empty))
    assert "record something first" in steps["index"].detail.lower()


def test_report_is_not_ready_when_the_server_is_down(cfg: RuntimeConfig) -> None:
    """'Ready' with nothing listening would send the user to watch their agent fail."""
    report = build_report(cfg)
    assert _steps(report)["server"].state == "todo"
    assert report.ready is False


def test_connector_step_states_its_prerequisite(cfg: RuntimeConfig) -> None:
    step = _steps(build_report(cfg))["connector"]
    assert step.state == "optional"
    assert "server you control" in step.detail


def test_connector_step_wants_a_passphrase_when_url_is_set(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("huske.mcp.oauth.load_password_hash", lambda path=None: None)
    cfg = RuntimeConfig(
        output_root=tmp_path / "t",
        index_root=tmp_path / "i",
        mcp_public_url="https://huske.example.com/mcp",
    )
    step = _steps(build_report(cfg))["connector"]
    assert step.state == "todo"
    assert step.fix == "huske mcp set-password"


def test_report_serializes_for_the_app(cfg: RuntimeConfig) -> None:
    payload = build_report(cfg).to_dict()
    assert set(payload) == {"ready", "endpoint", "connector_url", "steps"}
    assert payload["endpoint"].endswith("/mcp")
    assert all({"key", "title", "state", "detail", "fix", "can_apply"} == set(s) for s in payload["steps"])


# --- rendering -------------------------------------------------------------


def test_render_warns_that_the_server_stays_running(
    cfg: RuntimeConfig, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Otherwise `huske mcp` looks like a hung terminal.

    `extra_installed` is pinned rather than inherited from the environment: CI
    installs only `.[dev]`, so the extra is absent there and present locally,
    which would make this assert on a different render branch in each place.
    """
    monkeypatch.setattr("huske.setup.extra_installed", lambda: True)
    assert "keeps running" in render(build_report(cfg))


def test_render_hides_later_steps_while_one_is_blocked(
    cfg: RuntimeConfig, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A blocked step is the only instruction worth giving — listing the steps
    behind it invites the user to try them and fail."""
    monkeypatch.setattr("huske.setup.extra_installed", lambda: False)
    out = render(build_report(cfg))
    assert "Start here:" in out
    assert "keeps running" not in out
    assert "Next:" not in out


def test_render_points_at_the_blocking_step_first(
    cfg: RuntimeConfig, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("huske.setup.extra_installed", lambda: False)
    out = render(build_report(cfg))
    assert "Start here:" in out
    assert "huske setup` again" in out


def test_render_always_explains_the_phone_path(cfg: RuntimeConfig) -> None:
    assert "always-on server" in render(build_report(cfg))


# --- Claude Desktop wiring -------------------------------------------------


@pytest.fixture
def desktop(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    path = tmp_path / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    path.parent.mkdir(parents=True)
    monkeypatch.setattr("huske.setup.CLAUDE_DESKTOP_CONFIG", path)
    return path


def test_entry_writes_authorization_without_a_space(cfg: RuntimeConfig) -> None:
    """Claude Desktop strips spaces inside args, so a space breaks the header."""
    entry = claude_desktop_entry(cfg, "tok")
    assert "Authorization:${HUSKE_MCP_TOKEN}" in entry["args"]
    assert entry["env"]["HUSKE_MCP_TOKEN"] == "Bearer tok"


def test_apply_creates_a_config_when_absent(cfg: RuntimeConfig, desktop: Path) -> None:
    changed, message = apply_claude_desktop(cfg, "tok")
    assert changed is True
    assert "Quit and reopen" in message
    assert json.loads(desktop.read_text())["mcpServers"]["huske"]["command"] == "npx"


def test_apply_preserves_other_servers_and_keys(cfg: RuntimeConfig, desktop: Path) -> None:
    """This file may hold MCP servers the user depends on."""
    desktop.write_text(
        json.dumps(
            {
                "mcpServers": {"other": {"command": "node"}},
                "globalShortcut": "Alt+Space",
            }
        ),
        encoding="utf-8",
    )
    apply_claude_desktop(cfg, "tok")
    result = json.loads(desktop.read_text())
    assert result["mcpServers"]["other"] == {"command": "node"}
    assert result["globalShortcut"] == "Alt+Space"
    assert "huske" in result["mcpServers"]


def test_apply_backs_up_the_original_once(cfg: RuntimeConfig, desktop: Path) -> None:
    desktop.write_text(json.dumps({"mcpServers": {"other": {"command": "node"}}}), encoding="utf-8")
    backup = desktop.with_suffix(desktop.suffix + ".huske-backup")

    apply_claude_desktop(cfg, "tok")
    first = backup.read_text()
    assert "other" in first
    assert "huske" not in json.loads(first).get("mcpServers", {})

    # A second run must not overwrite the pre-huske snapshot with a post-huske one.
    apply_claude_desktop(cfg, "different-token")
    assert backup.read_text() == first


def test_apply_is_idempotent(cfg: RuntimeConfig, desktop: Path) -> None:
    apply_claude_desktop(cfg, "tok")
    changed, message = apply_claude_desktop(cfg, "tok")
    assert changed is False
    assert "already connected" in message.lower()


def test_apply_refuses_to_overwrite_unparseable_json(cfg: RuntimeConfig, desktop: Path) -> None:
    desktop.write_text("{ this is not json", encoding="utf-8")
    changed, message = apply_claude_desktop(cfg, "tok")
    assert changed is False
    assert "not valid JSON" in message
    assert desktop.read_text() == "{ this is not json"  # untouched


def test_apply_repairs_a_non_dict_mcpservers(cfg: RuntimeConfig, desktop: Path) -> None:
    desktop.write_text(json.dumps({"mcpServers": []}), encoding="utf-8")
    changed, _ = apply_claude_desktop(cfg, "tok")
    assert changed is True
    assert "huske" in json.loads(desktop.read_text())["mcpServers"]


def test_apply_without_claude_desktop_installed(cfg: RuntimeConfig, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.setup.CLAUDE_DESKTOP_CONFIG", tmp_path / "absent" / "c.json")
    changed, message = apply_claude_desktop(cfg, "tok")
    assert changed is False
    assert "not installed" in message


def test_apply_leaves_no_temp_file(cfg: RuntimeConfig, desktop: Path) -> None:
    apply_claude_desktop(cfg, "tok")
    assert not list(desktop.parent.glob("*.tmp"))


# --- command ---------------------------------------------------------------


@pytest.fixture(autouse=True)
def _quiet(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)


def test_setup_json_is_parseable(cfg: RuntimeConfig, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    config = tmp_path / "config.toml"
    config.write_text(
        f'output_root = "{cfg.output_root}"\nindex_root = "{cfg.index_root}"\n', encoding="utf-8"
    )
    run_setup(config_path=config, json_output=True)
    payload = json.loads(capsys.readouterr().out)
    assert payload["ready"] is False
    assert any(s["key"] == "index" for s in payload["steps"])


def test_setup_rejects_an_unknown_apply_target() -> None:
    result = CliRunner().invoke(
        app, ["setup", "--config", "/nonexistent.toml", "--apply", "gemini"]
    )
    assert result.exit_code == 2
    assert "unknown target" in result.stdout


def test_apply_all_includes_the_index_step() -> None:
    """The render advertises `--apply all` for the index; it must actually run it."""
    import inspect

    from huske.setup import _run_apply

    source = inspect.getsource(_run_apply)
    assert '"index", "claude-desktop", "claude-code"' in source


def test_cli_setup_runs() -> None:
    result = CliRunner().invoke(app, ["setup", "--config", "/nonexistent.toml"])
    assert result.exit_code in (0, 1)
    assert "huske setup" in result.stdout
