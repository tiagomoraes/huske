"""Tests for the system-audio backend selection in CaptureCoordinator.

Avoids touching real audio devices — we only check that the coordinator
picks the right backend class based on cfg.system_audio_backend and the
``is_tap_supported`` probe.
"""

from __future__ import annotations

from typing import Any

import numpy as np
import pytest

from huske.capture import coordinator as coord_mod
from huske.capture.coordinator import CaptureCoordinator
from huske.capture.system_audio import SystemAudioPermissionError
from huske.capture.system_audio_tap import CoreAudioTapPermissionError
from huske.config import RuntimeConfig


class _NullSink:
    def write_block(
        self,
        block: np.ndarray,
        source: str = "microphone",
        now: object | None = None,
    ) -> None:
        del block, source, now


class _FakeStream:
    started = False
    stopped = False

    def __init__(self, **_kwargs: Any) -> None:
        type(self).started = False
        type(self).stopped = False

    def start(self) -> None:
        type(self).started = True

    def stop(self, timeout: float = 5.0) -> None:
        type(self).stopped = True

    def drain_available(self) -> list:
        return []

    @property
    def last_callback_at(self) -> None:
        return None


class _FailingTap(_FakeStream):
    def start(self) -> None:
        raise CoreAudioTapPermissionError("simulated failure")


class _FailingSCK(_FakeStream):
    def start(self) -> None:
        raise SystemAudioPermissionError("simulated failure")


def _coord(
    cfg: RuntimeConfig, warnings: dict[str, str] | None = None
) -> CaptureCoordinator:
    # mic_device_index=None — we patch InputStream so it never runs.
    return CaptureCoordinator(
        cfg=cfg,
        mic_device_index=None,
        sink=_NullSink(),
        on_warning=warnings.__setitem__ if warnings is not None else None,
        on_warning_clear=(
            (lambda key: warnings.pop(key, None)) if warnings is not None else None
        ),
    )


@pytest.fixture
def patch_streams(monkeypatch: pytest.MonkeyPatch) -> dict[str, type]:
    """Replace mic and system-audio streams with fakes that don't touch hardware."""

    class FakeMic:
        def __init__(self, **_kwargs: Any) -> None:
            pass

        def start(self) -> None:
            pass

        def stop(self) -> None:
            pass

        def close(self) -> None:
            pass

    class FakeTap(_FakeStream):
        pass

    class FakeSCK(_FakeStream):
        pass

    monkeypatch.setattr("sounddevice.InputStream", FakeMic)
    monkeypatch.setattr(coord_mod, "CoreAudioTapStream", FakeTap)
    monkeypatch.setattr(coord_mod, "SystemAudioStream", FakeSCK)
    return {"tap": FakeTap, "sck": FakeSCK}


def test_auto_picks_tap_when_supported(
    monkeypatch: pytest.MonkeyPatch, patch_streams: dict[str, type], tmp_path
) -> None:
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: True)
    cfg = RuntimeConfig(
        system_audio_backend="auto",
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )
    coord = _coord(cfg)
    coord.start()
    try:
        assert isinstance(coord._system_stream, patch_streams["tap"])
        assert coord.system_active
    finally:
        coord.stop()


def test_auto_falls_back_to_sck_when_unsupported(
    monkeypatch: pytest.MonkeyPatch, patch_streams: dict[str, type], tmp_path
) -> None:
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: False)
    cfg = RuntimeConfig(
        system_audio_backend="auto",
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )
    coord = _coord(cfg)
    coord.start()
    try:
        assert isinstance(coord._system_stream, patch_streams["sck"])
    finally:
        coord.stop()


def test_force_sck(
    monkeypatch: pytest.MonkeyPatch, patch_streams: dict[str, type], tmp_path
) -> None:
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: True)
    cfg = RuntimeConfig(
        system_audio_backend="sck",
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )
    coord = _coord(cfg)
    coord.start()
    try:
        assert isinstance(coord._system_stream, patch_streams["sck"])
    finally:
        coord.stop()


def test_off_disables_system_audio(
    monkeypatch: pytest.MonkeyPatch, patch_streams: dict[str, type], tmp_path
) -> None:
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: True)
    cfg = RuntimeConfig(
        system_audio_backend="off",
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )
    coord = _coord(cfg)
    coord.start()
    try:
        assert coord._system_stream is None
        assert not coord.system_active
    finally:
        coord.stop()


def test_auto_falls_back_when_tap_start_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    """If tap.start() raises, auto mode should try SCK next."""
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: True)

    class FakeMic:
        def __init__(self, **_kwargs: Any) -> None:
            pass

        def start(self) -> None:
            pass

        def stop(self) -> None:
            pass

        def close(self) -> None:
            pass

    class WorkingSCK(_FakeStream):
        pass

    monkeypatch.setattr("sounddevice.InputStream", FakeMic)
    monkeypatch.setattr(coord_mod, "CoreAudioTapStream", _FailingTap)
    monkeypatch.setattr(coord_mod, "SystemAudioStream", WorkingSCK)

    cfg = RuntimeConfig(
        system_audio_backend="auto",
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )
    warnings: dict[str, str] = {}
    coord = _coord(cfg, warnings=warnings)
    coord.start()
    try:
        assert isinstance(coord._system_stream, WorkingSCK)
        assert coord.system_active
        assert "screen sharing" in warnings["system_audio_backend"]
    finally:
        coord.stop()


def test_force_tap_does_not_fall_back(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: True)

    class FakeMic:
        def __init__(self, **_kwargs: Any) -> None:
            pass

        def start(self) -> None:
            pass

        def stop(self) -> None:
            pass

        def close(self) -> None:
            pass

    class ShouldNotBeUsed(_FakeStream):
        pass

    monkeypatch.setattr("sounddevice.InputStream", FakeMic)
    monkeypatch.setattr(coord_mod, "CoreAudioTapStream", _FailingTap)
    monkeypatch.setattr(coord_mod, "SystemAudioStream", ShouldNotBeUsed)

    cfg = RuntimeConfig(
        system_audio_backend="tap",
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
    )
    coord = _coord(cfg)
    coord.start()
    try:
        # Tap failed, no fallback because backend was explicitly set.
        assert coord._system_stream is None
        assert not coord.system_active
    finally:
        coord.stop()
