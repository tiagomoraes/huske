"""Tests for doctor system-audio backend diagnostics."""

from __future__ import annotations

from pathlib import Path

import pytest

from huske.capture import system_audio as sck_mod
from huske.capture import system_audio_tap as tap_mod
from huske.config import RuntimeConfig
from huske.doctor import _system_audio_checks


def _cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )


def test_auto_reports_core_audio_tap_when_supported(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    class FakeTap:
        def __init__(self, **_kwargs: object) -> None:
            pass

        def start(self) -> None:
            pass

        def stop(self) -> None:
            pass

    monkeypatch.setattr(tap_mod, "is_supported", lambda: True)
    monkeypatch.setattr(tap_mod, "CoreAudioTapStream", FakeTap)

    checks = _system_audio_checks(_cfg(tmp_path))

    assert [c.name for c in checks] == ["system backend", "system audio"]
    assert checks[0].detail == "auto -> Core Audio tap"
    assert checks[1].ok
    assert checks[1].detail == "Core Audio process tap usable"


def test_auto_reports_screen_capturekit_fallback_when_tap_fails(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    class FailingTap:
        def __init__(self, **_kwargs: object) -> None:
            pass

        def start(self) -> None:
            raise RuntimeError("denied")

        def stop(self) -> None:
            pass

    monkeypatch.setattr(tap_mod, "is_supported", lambda: True)
    monkeypatch.setattr(tap_mod, "CoreAudioTapStream", FailingTap)
    monkeypatch.setattr(sck_mod, "check_permission", lambda timeout=5.0: True)

    checks = _system_audio_checks(_cfg(tmp_path))

    assert [c.name for c in checks] == [
        "system backend",
        "system audio",
        "system fallback",
    ]
    assert not checks[1].ok
    assert "Core Audio process tap unavailable" in checks[1].detail
    assert checks[2].ok
    assert checks[2].detail == "ScreenCaptureKit usable"
