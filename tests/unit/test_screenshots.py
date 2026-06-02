"""Tests for huske.screenshots and related path/config plumbing."""

from __future__ import annotations

import subprocess
from datetime import datetime
from pathlib import Path

import pytest

from huske import paths
from huske.config import RuntimeConfig
from huske.screenshots import ScreenshotCapturer

# ---------------------------------------------------------------------------
# Config defaults and validation
# ---------------------------------------------------------------------------


def test_screenshots_defaults_off() -> None:
    cfg = RuntimeConfig()
    assert cfg.screenshots_enabled is False
    assert cfg.screenshots_interval_seconds == 10.0
    assert cfg.screenshots_max_displays == 4
    assert cfg.screenshots_root.is_absolute()


def test_screenshots_interval_must_be_at_least_one_second() -> None:
    RuntimeConfig(screenshots_interval_seconds=1.0)
    with pytest.raises(ValueError):
        RuntimeConfig(screenshots_interval_seconds=0.5)
    with pytest.raises(ValueError):
        RuntimeConfig(screenshots_interval_seconds=0.0)
    with pytest.raises(ValueError):
        RuntimeConfig(screenshots_interval_seconds=-1.0)


def test_screenshots_interval_upper_bound() -> None:
    RuntimeConfig(screenshots_interval_seconds=3600.0)  # exact bound ok
    with pytest.raises(ValueError):
        RuntimeConfig(screenshots_interval_seconds=3600.1)


def test_screenshots_max_displays_bounds() -> None:
    RuntimeConfig(screenshots_max_displays=1)
    RuntimeConfig(screenshots_max_displays=16)
    with pytest.raises(ValueError):
        RuntimeConfig(screenshots_max_displays=0)
    with pytest.raises(ValueError):
        RuntimeConfig(screenshots_max_displays=17)


def test_screenshots_root_is_expanded() -> None:
    cfg = RuntimeConfig(screenshots_root="~/elsewhere")
    assert "~" not in str(cfg.screenshots_root)


# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------


def test_screenshot_filename_format() -> None:
    when = datetime(2026, 5, 7, 9, 15, 7)
    assert paths.screenshot_filename(when, 1) == "091507_d1.jpg"
    assert paths.screenshot_filename(when, 4) == "091507_d4.jpg"


def test_screenshots_session_dir(tmp_path: Path) -> None:
    cfg = RuntimeConfig(screenshots_root=tmp_path / "shots")
    when = datetime(2026, 5, 7, 9, 15, 0)
    target = paths.screenshots_session_dir(cfg, "20260507T091500_8a3f", when)
    assert target == tmp_path / "shots" / "2026-05-07" / "20260507T091500_8a3f"


# ---------------------------------------------------------------------------
# Capturer behavior — _capture_once unit
# ---------------------------------------------------------------------------


def _cfg(tmp_path: Path, *, max_displays: int = 4) -> RuntimeConfig:
    return RuntimeConfig(
        screenshots_enabled=True,
        screenshots_root=tmp_path / "shots",
        screenshots_interval_seconds=1.0,
        screenshots_max_displays=max_displays,
    )


def _fake_screencapture_writing(displays: int) -> subprocess.CompletedProcess[bytes]:
    """Build a fake subprocess.run that writes JPEGs for the first ``displays``
    file arguments, mimicking how real ``screencapture`` writes 1 file per
    attached display."""
    return subprocess.CompletedProcess(args=[], returncode=0, stdout=b"", stderr=b"")


def test_capture_once_writes_files_for_each_display(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg = _cfg(tmp_path, max_displays=3)
    cap = ScreenshotCapturer(cfg=cfg, session_id="sess1")

    captured_cmds: list[list[str]] = []

    def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        captured_cmds.append(cmd)
        # Real screencapture writes the first N files for N attached displays.
        # Simulate 2 of 3 displays present.
        for path_str in cmd[4:6]:
            Path(path_str).write_bytes(b"\xff\xd8fake-jpeg")
        return _fake_screencapture_writing(2)

    monkeypatch.setattr("huske.screenshots.capturer.subprocess.run", fake_run)

    when = datetime(2026, 5, 7, 9, 15, 0)
    written = cap._capture_once(when)

    assert written == 2
    assert cap.captures == 1
    assert cap.last_capture_at == when
    # The directory should be the expected day/session layout.
    target_dir = tmp_path / "shots" / "2026-05-07" / "sess1"
    assert (target_dir / "091500_d1.jpg").exists()
    assert (target_dir / "091500_d2.jpg").exists()
    assert not (target_dir / "091500_d3.jpg").exists()
    # And the command shape should match what we expect.
    assert captured_cmds[0][:4] == ["screencapture", "-x", "-t", "jpg"]
    assert len(captured_cmds[0]) == 4 + 3  # 3 file args


def test_capture_once_raises_when_screencapture_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg = _cfg(tmp_path)
    cap = ScreenshotCapturer(cfg=cfg, session_id="sess2")

    def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        return subprocess.CompletedProcess(
            args=cmd, returncode=1, stdout=b"", stderr=b"permission denied"
        )

    monkeypatch.setattr("huske.screenshots.capturer.subprocess.run", fake_run)

    with pytest.raises(RuntimeError, match="screencapture exit 1"):
        cap._capture_once(datetime.now().astimezone())
    assert cap.captures == 0


def test_capture_once_raises_when_no_files_produced(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg = _cfg(tmp_path)
    cap = ScreenshotCapturer(cfg=cfg, session_id="sess3")

    def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        # success exit code but writes nothing — surface as a clear error.
        return subprocess.CompletedProcess(args=cmd, returncode=0, stdout=b"", stderr=b"")

    monkeypatch.setattr("huske.screenshots.capturer.subprocess.run", fake_run)

    with pytest.raises(RuntimeError, match="produced no files"):
        cap._capture_once(datetime.now().astimezone())


# ---------------------------------------------------------------------------
# Lifecycle — start/stop without exercising the real `screencapture` binary
# ---------------------------------------------------------------------------


def test_start_skips_when_screencapture_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("huske.screenshots.capturer.shutil.which", lambda _: None)
    events: list[tuple[str, str]] = []
    cap = ScreenshotCapturer(
        cfg=_cfg(tmp_path),
        session_id="sess",
        on_event=lambda sev, msg: events.append((sev, msg)),
    )
    cap.start()
    assert not cap.alive
    assert events and events[0][0] == "warn"
    assert "screencapture" in events[0][1]


def test_loop_emits_warning_on_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg = _cfg(tmp_path)
    events: list[tuple[str, str]] = []

    def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        return subprocess.CompletedProcess(
            args=cmd, returncode=1, stdout=b"", stderr=b"boom"
        )

    monkeypatch.setattr("huske.screenshots.capturer.subprocess.run", fake_run)
    monkeypatch.setattr("huske.screenshots.capturer.shutil.which", lambda _: "/usr/sbin/screencapture")

    cap = ScreenshotCapturer(
        cfg=cfg, session_id="sess", on_event=lambda sev, msg: events.append((sev, msg))
    )
    cap.start()
    # Tight stop: the run loop attempts the first capture (which will fail), emits
    # a warn event, and then we cut it off before the next interval tick.
    cap.stop(timeout=2.0)

    warns = [e for e in events if e[0] == "warn"]
    assert warns, "expected at least one warn event"
    assert "screencapture" in warns[0][1]


def test_stop_is_idempotent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "huske.screenshots.capturer.shutil.which", lambda _: "/usr/sbin/screencapture"
    )

    def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        for path_str in cmd[4:5]:
            Path(path_str).write_bytes(b"\xff\xd8")
        return subprocess.CompletedProcess(args=cmd, returncode=0, stdout=b"", stderr=b"")

    monkeypatch.setattr("huske.screenshots.capturer.subprocess.run", fake_run)

    cap = ScreenshotCapturer(cfg=_cfg(tmp_path), session_id="sess")
    cap.start()
    cap.stop()
    cap.stop()  # second stop must not error
    assert not cap.alive
