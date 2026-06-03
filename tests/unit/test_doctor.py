"""Tests for doctor system-audio backend diagnostics."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from huske import agent
from huske.capture import system_audio as sck_mod
from huske.capture import system_audio_tap as tap_mod
from huske.config import RuntimeConfig
from huske.doctor import _autostart_check, _system_audio_checks


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


# ---------------------------------------------------------------------------
# _autostart_check — macOS login LaunchAgent diagnostics (opt-in, informational)
# ---------------------------------------------------------------------------


def _status(tmp_path: Path, **overrides: object) -> agent.AgentStatus:
    defaults: dict[str, object] = {
        "installed": False,
        "loaded": False,
        "pid": None,
        "last_exit_code": None,
        "plist_path": tmp_path / "me.huske.plist",
        "log_out": tmp_path / "agent.out.log",
        "log_err": tmp_path / "agent.err.log",
    }
    defaults.update(overrides)
    return agent.AgentStatus(**defaults)  # type: ignore[arg-type]


def test_autostart_check_not_installed_is_ok(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(agent, "agent_status", lambda: _status(tmp_path))

    check = _autostart_check()

    assert check is not None
    assert check.name == "autostart"
    assert check.ok is True  # opt-in: absence must never fail doctor
    assert "not installed" in check.detail


def test_autostart_check_installed_and_running(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    plist = tmp_path / "me.huske.plist"
    monkeypatch.setattr(
        agent,
        "agent_status",
        lambda: _status(tmp_path, installed=True, loaded=True, pid=4321, plist_path=plist),
    )

    check = _autostart_check()

    assert check is not None
    assert check.ok is True
    assert "running" in check.detail
    assert str(plist) in check.detail
    assert "pid 4321" in check.detail


def test_autostart_check_installed_not_loaded_surfaces_crash(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    err = tmp_path / "agent.err.log"
    monkeypatch.setattr(
        agent,
        "agent_status",
        lambda: _status(tmp_path, installed=True, loaded=False, last_exit_code=78, log_err=err),
    )

    check = _autostart_check()

    assert check is not None
    assert check.ok is True  # a crashed opt-in agent still must not fail doctor
    assert "not loaded" in check.detail
    assert "last exit 78" in check.detail
    assert str(err) in check.detail


def test_autostart_check_skipped_off_macos(monkeypatch: pytest.MonkeyPatch) -> None:
    # agent_status() calls _ensure_macos() first; off Darwin it raises and the
    # check is skipped entirely (returns None), so it never clutters output or
    # affects the exit code on non-macOS.
    monkeypatch.setattr(agent.platform, "system", lambda: "Linux")

    assert _autostart_check() is None
