"""Tests for doctor system-audio backend diagnostics."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from huske.capture import system_audio as sck_mod
from huske.capture import system_audio_tap as tap_mod
from huske.config import RuntimeConfig
from huske.doctor import _system_audio_checks


def _cfg(tmp_path: Path, system_audio_backend: str = "auto") -> RuntimeConfig:
    return RuntimeConfig(
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
        system_audio_backend=system_audio_backend,
    )


def test_auto_reports_core_audio_tap_without_starting_probe(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    class UnexpectedTap:
        def __init__(self, **_kwargs: object) -> None:
            raise AssertionError("auto doctor must not start the tap backend")

    monkeypatch.setattr(tap_mod, "is_supported", lambda: True)
    monkeypatch.setattr(tap_mod, "CoreAudioTapStream", UnexpectedTap)

    checks = _system_audio_checks(_cfg(tmp_path))

    assert [c.name for c in checks] == ["system backend", "system audio"]
    assert checks[0].detail == "auto -> Core Audio tap"
    assert checks[1].ok
    assert checks[1].detail == "Core Audio process tap available; permission not probed"
    assert checks[1].hint is not None
    assert "--system-audio-backend tap" in checks[1].hint


def test_auto_reports_screen_capturekit_without_permission_probe(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(tap_mod, "is_supported", lambda: False)
    monkeypatch.setitem(sys.modules, "ScreenCaptureKit", SimpleNamespace())
    monkeypatch.setattr(
        sck_mod,
        "check_permission",
        lambda timeout=5.0: (_ for _ in ()).throw(
            AssertionError("auto doctor must not query ScreenCaptureKit permission")
        ),
    )

    checks = _system_audio_checks(_cfg(tmp_path))

    assert [c.name for c in checks] == ["system backend", "system audio"]
    assert checks[0].detail == "auto -> ScreenCaptureKit"
    assert checks[1].ok
    assert checks[1].detail == "ScreenCaptureKit available; permission not probed"
    assert checks[1].hint is not None
    assert "--system-audio-backend sck" in checks[1].hint


def test_forced_tap_validates_core_audio_tap(
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

    checks = _system_audio_checks(_cfg(tmp_path, system_audio_backend="tap"))

    assert [c.name for c in checks] == ["system backend", "system audio"]
    assert checks[0].detail == "forced Core Audio tap"
    assert checks[1].ok
    assert checks[1].detail == "Core Audio process tap usable"


def test_forced_tap_reports_core_audio_tap_failure(
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

    checks = _system_audio_checks(_cfg(tmp_path, system_audio_backend="tap"))

    assert [c.name for c in checks] == ["system backend", "system audio"]
    assert not checks[1].ok
    assert "Core Audio process tap unavailable" in checks[1].detail


def test_forced_sck_validates_screen_capturekit_permission(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(sck_mod, "check_permission", lambda timeout=5.0: True)

    checks = _system_audio_checks(_cfg(tmp_path, system_audio_backend="sck"))

    assert [c.name for c in checks] == ["system backend", "system audio"]
    assert checks[0].detail == "forced ScreenCaptureKit (may stop during screen sharing)"
    assert checks[1].ok
    assert checks[1].detail == "ScreenCaptureKit usable"
