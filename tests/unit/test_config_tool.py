"""Tests for `huske config` / `huske devices` (huske/config_tool.py)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from huske.config_tool import (
    list_devices,
    set_config_value,
    show_config,
    unset_config_value,
)


@pytest.fixture
def config_path(tmp_path: Path) -> Path:
    return tmp_path / "config.toml"


# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------


def test_show_json_reports_effective_and_file_keys(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config_path.write_text('chunk_minutes = 5.0\n', encoding="utf-8")

    assert show_config(config_path=config_path, json_output=True) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["path"] == str(config_path)
    assert payload["exists"] is True
    assert payload["file"] == {"chunk_minutes": 5.0}
    assert payload["effective"]["chunk_minutes"] == 5.0
    assert payload["effective"]["asr_engine"] == "parakeet"  # default fills in


def test_show_json_for_missing_file_uses_defaults(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert show_config(config_path=config_path, json_output=True) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["exists"] is False
    assert payload["file"] == {}
    assert payload["effective"]["chunk_minutes"] == 30.0


def test_show_human_marks_explicit_keys(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config_path.write_text('model = "small"\n', encoding="utf-8")
    assert show_config(config_path=config_path, json_output=False) == 0
    out = capsys.readouterr().out
    assert "* model" in out


def test_show_reports_invalid_config(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config_path.write_text('chunk_minutes = 999.0\n', encoding="utf-8")
    assert show_config(config_path=config_path, json_output=True) == 2
    payload = json.loads(capsys.readouterr().out)
    assert "error" in payload


# ---------------------------------------------------------------------------
# set / unset
# ---------------------------------------------------------------------------


def test_set_types_json_scalars(config_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert set_config_value("chunk_minutes", "5.0", config_path=config_path) == 0
    assert set_config_value("speech_gated", "false", config_path=config_path) == 0
    assert set_config_value("input_device", "MacBook Pro Microphone", config_path=config_path) == 0

    import tomllib

    data = tomllib.loads(config_path.read_text(encoding="utf-8"))
    assert data == {
        "chunk_minutes": 5.0,
        "speech_gated": False,
        "input_device": "MacBook Pro Microphone",
    }


def test_set_rejects_invalid_value_without_writing(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert set_config_value("chunk_minutes", "999", config_path=config_path) == 2
    assert not config_path.exists()
    assert "chunk_minutes" in capsys.readouterr().out


def test_set_rejects_unknown_key(config_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert set_config_value("no_such_key", "1", config_path=config_path) == 2
    assert not config_path.exists()


def test_unset_removes_key_and_preserves_others(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    config_path.write_text('chunk_minutes = 5.0\nmodel = "small"\n', encoding="utf-8")

    assert unset_config_value("chunk_minutes", config_path=config_path) == 0

    import tomllib

    data = tomllib.loads(config_path.read_text(encoding="utf-8"))
    assert data == {"model": "small"}


def test_unset_unknown_key_errors(config_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert unset_config_value("bogus", config_path=config_path) == 2


def test_unset_key_not_in_file_is_a_noop(
    config_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert unset_config_value("chunk_minutes", config_path=config_path) == 0
    assert not config_path.exists()


# ---------------------------------------------------------------------------
# devices
# ---------------------------------------------------------------------------


def test_devices_json_lists_devices(
    config_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from huske.capture.devices import DeviceInfo, DeviceResolution

    fake = [
        DeviceInfo(index=1, name="MacBook Pro Microphone", max_input_channels=1,
                   default_samplerate=48000.0, host_api="Core Audio"),
        DeviceInfo(index=3, name="AirPods Pro", max_input_channels=1,
                   default_samplerate=24000.0, host_api="Core Audio"),
    ]
    monkeypatch.setattr("huske.capture.devices.list_input_devices", lambda: fake)
    monkeypatch.setattr(
        "huske.capture.devices.resolve_input_device_with_fallback",
        lambda name: DeviceResolution(device=fake[0], requested_name=name),
    )

    assert list_devices(config_path=config_path, json_output=True) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["resolved_index"] == 1
    assert [d["name"] for d in payload["devices"]] == [
        "MacBook Pro Microphone",
        "AirPods Pro",
    ]
    assert payload["devices"][0]["host_api"] == "Core Audio"
