"""CLI-to-config precedence tests.

Regression coverage for ``huske run`` flag handling: defaults that fall
through to the config layer must remain ``Optional`` (default ``None``) so
``_collect_overrides`` strips them; otherwise they masquerade as explicit
overrides and silently overwrite the config file value.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from typer.testing import CliRunner

from huske.cli import _collect_overrides, app


@pytest.fixture
def cli(monkeypatch: pytest.MonkeyPatch) -> Iterator[tuple[CliRunner, dict[str, object]]]:
    """Stub run_session so invoking ``huske run`` short-circuits without I/O."""
    captured: dict[str, object] = {}

    def fake_run_session(config_path=None, cli_overrides=None):  # type: ignore[no-untyped-def]
        captured["config_path"] = config_path
        captured["cli_overrides"] = dict(cli_overrides or {})
        return 0

    monkeypatch.setattr("huske.run_loop.run_session", fake_run_session)
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    yield CliRunner(), captured


def test_collect_overrides_strips_none_values() -> None:
    result = _collect_overrides(menu_bar_enabled=None, screenshots_enabled=False)
    assert "menu_bar_enabled" not in result
    assert result["screenshots_enabled"] is False


def test_run_without_menu_bar_flag_does_not_override_config(
    cli: tuple[CliRunner, dict[str, object]],
) -> None:
    runner, captured = cli
    result = runner.invoke(app, ["run"])
    assert result.exit_code == 0, result.output
    assert "menu_bar_enabled" not in captured["cli_overrides"]  # type: ignore[operator]


def test_run_with_no_menu_bar_overrides_config(
    cli: tuple[CliRunner, dict[str, object]],
) -> None:
    runner, captured = cli
    result = runner.invoke(app, ["run", "--no-menu-bar"])
    assert result.exit_code == 0, result.output
    assert captured["cli_overrides"]["menu_bar_enabled"] is False  # type: ignore[index]


def test_run_with_menu_bar_overrides_config(
    cli: tuple[CliRunner, dict[str, object]],
) -> None:
    runner, captured = cli
    result = runner.invoke(app, ["run", "--menu-bar"])
    assert result.exit_code == 0, result.output
    assert captured["cli_overrides"]["menu_bar_enabled"] is True  # type: ignore[index]


def test_doctor_accepts_system_audio_backend_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, object] = {}

    def fake_run_doctor(config_path=None, cli_overrides=None, json_output=False):  # type: ignore[no-untyped-def]
        captured["config_path"] = config_path
        captured["cli_overrides"] = dict(cli_overrides or {})
        captured["json_output"] = json_output
        return 0

    monkeypatch.setattr("huske.doctor.run_doctor", fake_run_doctor)
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)

    result = CliRunner().invoke(app, ["doctor", "--system-audio-backend", "tap"])

    assert result.exit_code == 0, result.output
    assert captured["cli_overrides"]["system_audio_backend"] == "tap"  # type: ignore[index]


def test_serve_passes_overrides_to_config(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def fake_run_serve(cfg):  # type: ignore[no-untyped-def]
        captured["ingest_port"] = cfg.ingest_port
        captured["public_host"] = cfg.public_host
        return 0

    monkeypatch.setattr("huske.server.serve.run", fake_run_serve)
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)

    result = CliRunner().invoke(
        app, ["serve", "--ingest-port", "9000", "--public-host", "huske.example.com"]
    )
    assert result.exit_code == 0, result.output
    assert captured["ingest_port"] == 9000
    assert captured["public_host"] == "huske.example.com"


def test_sync_invokes_runner(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def fake_run_sync(config_path=None, cli_overrides=None):  # type: ignore[no-untyped-def]
        captured["cli_overrides"] = dict(cli_overrides or {})
        return 0

    monkeypatch.setattr("huske.sync.runner.run_sync", fake_run_sync)
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)

    result = CliRunner().invoke(app, ["sync"])
    assert result.exit_code == 0, result.output
    assert captured["cli_overrides"] == {}


def test_autostart_stop_reports_when_already_stopped(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("huske.agent._ensure_macos", lambda: None)
    monkeypatch.setattr("huske.agent.stop_agent", lambda: False)
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)

    result = CliRunner().invoke(app, ["autostart", "stop"])

    assert result.exit_code == 0, result.output
    assert "already stopped" in result.output
