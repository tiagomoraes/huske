"""Tests for CaptureCoordinator.reclaim_mic — the mic-doctor recovery path.

The scenario behind these tests: `huske run` starts at login before the
configured Bluetooth microphone has connected, falls back to the built-in
mic, and must claim the configured device once it appears. PortAudio only
sees hot-plugged devices after a re-initialization, so `reclaim_mic` closes
the stream, refreshes PortAudio, re-resolves, and reopens.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import ClassVar

import pytest

from huske.capture import coordinator as coordinator_mod
from huske.capture import devices as devices_mod
from huske.capture.coordinator import CaptureCoordinator
from huske.config import RuntimeConfig

MACBOOK = {
    "name": "MacBook Pro Microphone",
    "hostapi": 0,
    "max_input_channels": 1,
    "default_samplerate": 48000.0,
}
AIRPODS = {
    "name": "Tiago's AirPods Pro",
    "hostapi": 0,
    "max_input_channels": 1,
    "default_samplerate": 24000.0,
}


class FakeInputStream:
    """Stands in for sd.InputStream; records lifecycle + target device."""

    instances: ClassVar[list[FakeInputStream]] = []
    fail_devices: ClassVar[set[int]] = set()

    def __init__(self, device: int | None = None, **_: object) -> None:
        if device in self.fail_devices:
            raise RuntimeError(f"device {device} refused to open")
        self.device = device
        self.started = False
        self.closed = False
        FakeInputStream.instances.append(self)

    def start(self) -> None:
        self.started = True

    def stop(self) -> None:
        self.started = False

    def close(self) -> None:
        self.closed = True


class _NullSink:
    def write_block(self, block, source="microphone", now=None, is_speech=True):  # type: ignore[no-untyped-def]
        pass


@pytest.fixture
def fake_sd(monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    """Patch the shared sounddevice module for coordinator + devices.

    Both modules import the same `sounddevice` module object, so patching
    attributes on either module's `sd` reference covers both. Returns a
    handle whose `raw_devices` list can be mutated to simulate hot-plug;
    the new list only becomes visible after `_terminate` + `_initialize`
    (mirroring PortAudio's snapshot behavior).
    """
    FakeInputStream.instances = []
    FakeInputStream.fail_devices = set()

    handle = SimpleNamespace(
        raw_devices=[MACBOOK],
        visible_devices=[MACBOOK],
        terminated=0,
        initialized=0,
    )

    sd = coordinator_mod.sd
    assert devices_mod.__dict__["sd"] is sd

    def _terminate() -> None:
        handle.terminated += 1

    def _initialize() -> None:
        handle.initialized += 1
        handle.visible_devices = list(handle.raw_devices)

    def query_devices(index: int | None = None) -> object:
        if index is None:
            return handle.visible_devices
        return handle.visible_devices[index]

    monkeypatch.setattr(sd, "_terminate", _terminate)
    monkeypatch.setattr(sd, "_initialize", _initialize)
    monkeypatch.setattr(sd, "query_devices", query_devices)
    monkeypatch.setattr(sd, "query_hostapis", lambda: [{"name": "Core Audio"}])
    monkeypatch.setattr(sd, "default", SimpleNamespace(device=[0, -1]))
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    return handle


def _coordinator_on_fallback(events: list[tuple[str, str]] | None = None) -> CaptureCoordinator:
    """A coordinator whose mic runs on the fallback device (index 0)."""
    cfg = RuntimeConfig(system_audio_backend="off")
    coord = CaptureCoordinator(
        cfg,
        mic_device_index=0,
        sink=_NullSink(),
        on_event=(lambda s, m: events.append((s, m))) if events is not None else None,
        system_audio=False,
    )
    # Attach a live mic stream directly instead of running start(), which
    # would spawn the mixer thread this test doesn't need.
    stream = FakeInputStream(device=0)
    stream.start()
    coord._mic_stream = stream
    coord._mic_active = True
    return coord


def test_reclaims_requested_device_once_it_appears(fake_sd: SimpleNamespace) -> None:
    coord = _coordinator_on_fallback()
    old_stream = coord._mic_stream

    fake_sd.raw_devices = [MACBOOK, AIRPODS]  # AirPods connect after startup

    resolution = coord.reclaim_mic("AirPods")

    assert fake_sd.terminated == 1 and fake_sd.initialized == 1
    assert old_stream.closed
    assert resolution is not None
    assert not resolution.fallback_used
    assert resolution.device is not None
    assert resolution.device.name == AIRPODS["name"]
    assert coord.mic_device_index == 1
    assert coord.mic_active
    assert coord._mic_stream is not None and coord._mic_stream.device == 1
    assert coord._mic_stream.started


def test_requested_device_still_missing_reopens_fallback(fake_sd: SimpleNamespace) -> None:
    coord = _coordinator_on_fallback()

    resolution = coord.reclaim_mic("AirPods")

    assert resolution is not None
    assert resolution.fallback_used
    assert resolution.device is not None
    assert resolution.device.name == MACBOOK["name"]
    assert coord.mic_active
    assert coord._mic_stream is not None and coord._mic_stream.device == 0


def test_requested_device_visible_but_unopenable_falls_back(fake_sd: SimpleNamespace) -> None:
    events: list[tuple[str, str]] = []
    coord = _coordinator_on_fallback(events)

    fake_sd.raw_devices = [MACBOOK, AIRPODS]
    FakeInputStream.fail_devices = {1}  # AirPods enumerate but refuse a stream

    resolution = coord.reclaim_mic("AirPods")

    assert resolution is not None
    assert resolution.fallback_used  # caller keeps retrying later
    assert coord.mic_active
    assert coord._mic_stream is not None and coord._mic_stream.device == 0


def test_no_device_at_all_leaves_mic_off_and_warns(
    fake_sd: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    warnings: list[tuple[str, str]] = []
    cfg = RuntimeConfig(system_audio_backend="off")
    coord = CaptureCoordinator(
        cfg,
        mic_device_index=0,
        sink=_NullSink(),
        system_audio=False,
        on_warning=lambda k, m: warnings.append((k, m)),
    )
    stream = FakeInputStream(device=0)
    stream.start()
    coord._mic_stream = stream
    coord._mic_active = True

    fake_sd.raw_devices = []
    fake_sd.visible_devices = []
    monkeypatch.setattr(coordinator_mod.sd, "default", SimpleNamespace(device=[-1, -1]))

    resolution = coord.reclaim_mic("AirPods")

    assert resolution is None
    assert not coord.mic_active
    assert coord._mic_stream is None
    assert any(key == "microphone" for key, _ in warnings)


def test_reclaim_preserves_pause_state(fake_sd: SimpleNamespace) -> None:
    coord = _coordinator_on_fallback()
    coord.pause()
    fake_sd.raw_devices = [MACBOOK, AIRPODS]

    resolution = coord.reclaim_mic("AirPods")

    assert resolution is not None and not resolution.fallback_used
    assert coord.paused  # was paused before reclaim, stays paused

    coord.resume()
    resolution2 = coord.reclaim_mic("AirPods")
    assert resolution2 is not None
    assert not coord.paused  # was live before reclaim, resumes
