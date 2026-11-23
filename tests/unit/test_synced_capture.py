"""Synced capture mode in CaptureCoordinator (mic + system on one clock).

Never touches real hardware: ``open_synced_capture`` is replaced by a fake
aggregate that hands out paired mic/system blocks, and the separate-stream
backends are fakes too.
"""

from __future__ import annotations

import threading
import time
from datetime import datetime
from typing import Any, ClassVar

import numpy as np
import pytest

from huske.capture import coordinator as coord_mod
from huske.capture.coordinator import CaptureCoordinator
from huske.capture.synced_capture import SyncedCaptureError
from huske.config import RuntimeConfig


class _RecordingSink:
    def __init__(self) -> None:
        self.blocks: list[tuple[str, int]] = []
        self.lock = threading.Lock()

    def write_block(
        self,
        block: np.ndarray,
        source: str = "microphone",
        now: object | None = None,
        is_speech: bool = True,
    ) -> None:
        with self.lock:
            self.blocks.append((source, int(block.shape[0])))


class FakeSynced:
    """Stands in for SyncedCaptureStream: equal-length mic/system blocks."""

    instances: ClassVar[list[FakeSynced]] = []

    def __init__(self, mic_name: str | None, rate: int = 48000, deliver: bool = True) -> None:
        self.mic_name = mic_name
        self.sample_rate = rate
        self.deliver = deliver
        self.stopped = False
        self._pending: list[tuple[np.ndarray, np.ndarray, datetime]] = []
        self.last_callback_at: datetime | None = None
        FakeSynced.instances.append(self)

    def feed(self, seconds: float) -> None:
        n = int(seconds * self.sample_rate)
        now = datetime.now().astimezone()
        mic = np.full(n, 0.1, dtype=np.float32)
        sys_ = np.full(n, 0.2, dtype=np.float32)
        self._pending.append((mic, sys_, now))
        self.last_callback_at = now

    def drain_available(self) -> list[tuple[np.ndarray, np.ndarray, datetime]]:
        if self.deliver:
            self.feed(0.05)
        out, self._pending = self._pending, []
        return out

    def stop(self, timeout: float = 5.0) -> None:
        self.stopped = True


class _FakeStream:
    instances: ClassVar[list[Any]] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.started = False
        type(self).instances.append(self)

    def start(self) -> None:
        self.started = True

    def stop(self, timeout: float = 5.0) -> None:
        self.started = False

    def close(self) -> None:
        pass

    def drain_available(self) -> list:
        return []

    @property
    def last_callback_at(self) -> None:
        return None


@pytest.fixture
def fakes(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    class FakeMic(_FakeStream):
        instances: ClassVar[list[Any]] = []

    class FakeTap(_FakeStream):
        instances: ClassVar[list[Any]] = []

    class FakeSCK(_FakeStream):
        instances: ClassVar[list[Any]] = []

    FakeSynced.instances = []
    state: dict[str, Any] = {"fail": False, "rate": 48000, "deliver": True}

    def fake_open(mic_name: str | None, on_event: Any) -> FakeSynced:
        if state["fail"]:
            raise SyncedCaptureError("simulated: aggregate refused")
        return FakeSynced(mic_name, rate=state["rate"], deliver=state["deliver"])

    monkeypatch.setattr("sounddevice.InputStream", FakeMic)
    monkeypatch.setattr(
        "sounddevice.query_devices",
        lambda idx=None, *a, **k: {"name": f"Mic {idx}", "max_input_channels": 1},
    )
    monkeypatch.setattr(coord_mod, "CoreAudioTapStream", FakeTap)
    monkeypatch.setattr(coord_mod, "SystemAudioStream", FakeSCK)
    monkeypatch.setattr(coord_mod, "is_tap_supported", lambda: True)
    monkeypatch.setattr(coord_mod, "open_synced_capture", fake_open)
    return {"mic": FakeMic, "tap": FakeTap, "sck": FakeSCK, "state": state}


def _cfg(tmp_path: Any, **kw: Any) -> RuntimeConfig:
    return RuntimeConfig(
        output_root=tmp_path / "o",
        audio_root=tmp_path / "a",
        logs_root=tmp_path / "l",
        **kw,
    )


def _wait_for(pred: Any, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.02)
    return False


def test_synced_mode_replaces_both_streams(tmp_path: Any, fakes: dict[str, Any]) -> None:
    sink = _RecordingSink()
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=3, sink=sink)
    coord.start()
    try:
        assert coord.synced
        assert coord.mic_active and coord.system_active
        assert fakes["mic"].instances == []  # no PortAudio mic
        assert fakes["tap"].instances == []  # no separate tap
        assert FakeSynced.instances[0].mic_name == "Mic 3"
        assert _wait_for(lambda: len(sink.blocks) >= 6)
    finally:
        coord.stop()
    assert FakeSynced.instances[0].stopped
    # Mic and system blocks are always written in equal-length pairs.
    with sink.lock:
        mic = [n for s, n in sink.blocks if s == "microphone"]
        sys_ = [n for s, n in sink.blocks if s == "system"]
    assert len(mic) == len(sys_)
    assert mic[: len(sys_)] == sys_[: len(mic)]


def test_falls_back_to_separate_streams_when_aggregate_fails(
    tmp_path: Any, fakes: dict[str, Any]
) -> None:
    fakes["state"]["fail"] = True
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=1, sink=_RecordingSink())
    coord.start()
    try:
        assert not coord.synced
        assert len(fakes["mic"].instances) == 1
        assert len(fakes["tap"].instances) == 1
        assert coord.mic_active and coord.system_active
    finally:
        coord.stop()


@pytest.mark.parametrize(
    "overrides",
    [{"capture_sync": False}, {"system_audio_backend": "sck"}, {"system_audio_backend": "off"}],
)
def test_synced_mode_only_when_enabled_and_tap_backend(
    tmp_path: Any, fakes: dict[str, Any], overrides: dict[str, Any]
) -> None:
    coord = CaptureCoordinator(cfg=_cfg(tmp_path, **overrides), mic_device_index=1, sink=_RecordingSink())
    coord.start()
    try:
        assert not coord.synced
        assert FakeSynced.instances == []
    finally:
        coord.stop()


def test_stalled_aggregate_falls_back(
    tmp_path: Any, fakes: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coord_mod, "_SYNCED_STALL_SECONDS", 0.1)
    fakes["state"]["deliver"] = False  # never produces a callback
    events: list[tuple[str, str]] = []
    coord = CaptureCoordinator(
        cfg=_cfg(tmp_path),
        mic_device_index=2,
        sink=_RecordingSink(),
        on_event=lambda s, m: events.append((s, m)),
    )
    coord.start()
    try:
        assert coord.synced
        assert _wait_for(lambda: not coord.synced)
        assert len(fakes["mic"].instances) == 1
        assert len(fakes["tap"].instances) == 1
        assert any("separate streams" in m for _, m in events)
    finally:
        coord.stop()
    assert FakeSynced.instances[0].stopped


def test_swap_mic_rebuilds_aggregate(tmp_path: Any, fakes: dict[str, Any]) -> None:
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=1, sink=_RecordingSink())
    coord.start()
    try:
        assert coord.swap_mic_device(5)
        assert coord.synced
        assert coord.mic_device_index == 5
        assert [s.mic_name for s in FakeSynced.instances] == ["Mic 1", "Mic 5"]
        assert FakeSynced.instances[0].stopped
    finally:
        coord.stop()


def test_swap_mic_falls_back_when_new_aggregate_fails(
    tmp_path: Any, fakes: dict[str, Any]
) -> None:
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=1, sink=_RecordingSink())
    coord.start()
    try:
        fakes["state"]["fail"] = True
        assert coord.swap_mic_device(4)
        assert not coord.synced
        assert coord.mic_device_index == 4
        assert fakes["mic"].instances[-1].kwargs["device"] == 4
        assert len(fakes["tap"].instances) == 1
    finally:
        coord.stop()


def test_resamples_when_aggregate_rate_differs(tmp_path: Any, fakes: dict[str, Any]) -> None:
    fakes["state"]["rate"] = 24000  # e.g. a Bluetooth headset mic as clock
    sink = _RecordingSink()
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=1, sink=sink)
    coord.start()
    try:
        assert coord.synced
        assert _wait_for(lambda: len(sink.blocks) >= 4)
    finally:
        coord.stop()
    with sink.lock:
        mic = sum(n for s, n in sink.blocks if s == "microphone")
        sys_ = sum(n for s, n in sink.blocks if s == "system")
    assert mic == sys_


def _resolution(index: int, name: str) -> Any:
    from huske.capture.devices import DeviceInfo, DeviceResolution

    return DeviceResolution(
        device=DeviceInfo(index, name, 1, 48000.0, "Core Audio"),
        requested_name=name,
    )


def test_reclaim_rebuilds_aggregate_on_resolved_mic(
    tmp_path: Any, fakes: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("sounddevice._terminate", lambda: None)
    monkeypatch.setattr("sounddevice._initialize", lambda: None)
    monkeypatch.setattr(
        coord_mod, "resolve_input_device_with_fallback", lambda name: _resolution(7, "Mic 7")
    )
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=1, sink=_RecordingSink())
    coord.start()
    try:
        res = coord.reclaim_mic("Mic 7")
        assert res is not None and res.device is not None and res.device.index == 7
        assert coord.synced
        assert coord.mic_device_index == 7
        assert FakeSynced.instances[0].stopped
        assert fakes["mic"].instances == []
    finally:
        coord.stop()


def test_reclaim_falls_back_to_separate_streams(
    tmp_path: Any, fakes: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("sounddevice._terminate", lambda: None)
    monkeypatch.setattr("sounddevice._initialize", lambda: None)
    monkeypatch.setattr(
        coord_mod, "resolve_input_device_with_fallback", lambda name: _resolution(7, "Mic 7")
    )
    coord = CaptureCoordinator(cfg=_cfg(tmp_path), mic_device_index=1, sink=_RecordingSink())
    coord.start()
    try:
        fakes["state"]["fail"] = True
        res = coord.reclaim_mic("Mic 7")
        assert res is not None
        assert not coord.synced
        assert coord.mic_active and coord.system_active
        assert fakes["mic"].instances[-1].kwargs["device"] == 7
        assert len(fakes["tap"].instances) == 1
    finally:
        coord.stop()
