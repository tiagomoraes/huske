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
