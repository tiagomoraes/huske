"""Tests for the internal _SourceBuffer in capture/coordinator.py.

These don't touch sounddevice or ScreenCaptureKit — pure buffer logic.
"""

from __future__ import annotations

import threading

import numpy as np
import pytest

from huske.capture.coordinator import _pad_to_length, _SourceBuffer, _to_db


def _block(n: int, fill: float = 0.5) -> np.ndarray:
    return np.full(n, fill, dtype=np.float32)


def test_push_and_take_basic() -> None:
    buf = _SourceBuffer(max_frames=10_000)
    buf.push(_block(100, 0.1))
    buf.push(_block(50, 0.2))
    assert buf.available == 150

    out = buf.take(80)
    assert out.shape == (80,)
    assert np.allclose(out, 0.1)
    assert buf.available == 70

    # Crosses the boundary between the two pushed blocks.
    out2 = buf.take(40)
    assert out2.shape == (40,)
    assert np.allclose(out2[:20], 0.1)
    assert np.allclose(out2[20:], 0.2)
    assert buf.available == 30


def test_take_more_than_available_returns_what_is_there() -> None:
    buf = _SourceBuffer(max_frames=1_000)
    buf.push(_block(10, 0.5))
    out = buf.take(50)
    assert out.shape == (10,)
    assert buf.available == 0


def test_take_with_empty_returns_zero_length() -> None:
    buf = _SourceBuffer(max_frames=100)
    out = buf.take(50)
    assert out.shape == (0,)


def test_overflow_drops_oldest() -> None:
    """Overflow protection drops oldest pushed chunks (whole-chunk granularity)."""
    buf = _SourceBuffer(max_frames=300)
    buf.push(_block(200, 0.1))  # buffer = 200
    dropped = buf.push(_block(200, 0.2))  # buffer would be 400 → drop the oldest 200-chunk
    assert dropped is True
    # Whole-chunk drop: the [0.1] block is gone, only the [0.2] block remains.
    assert buf.available == 200
    out = buf.take(200)
    assert np.allclose(out, 0.2)


def test_thread_safety() -> None:
    """Hammer the buffer from multiple producers and consumers."""
    buf = _SourceBuffer(max_frames=100_000)
    errors: list[Exception] = []

    def producer() -> None:
        try:
            for _ in range(200):
                buf.push(_block(50, 0.7))
        except Exception as exc:
            errors.append(exc)

    def consumer() -> None:
        try:
            for _ in range(200):
                buf.take(20)
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=producer) for _ in range(4)] + [
        threading.Thread(target=consumer) for _ in range(4)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []


def test_to_db_helper() -> None:
    assert _to_db(0.0) == -120.0
    assert _to_db(1.0) == 0.0
    assert _to_db(0.5) == pytest.approx(-6.0206, abs=0.01)
    assert _to_db(2.0) == 0.0  # clamped at 1.0


def test_pad_to_length_trailing_silence() -> None:
    """Short block gets trailing zeros up to target length."""
    part = np.full(200, 0.5, dtype=np.float32)
    out = _pad_to_length(part, 800)
    assert out.shape == (800,)
    assert np.allclose(out[:200], 0.5)
    assert np.allclose(out[200:], 0.0)


def test_pad_to_length_passthrough_when_already_long_enough() -> None:
    part = np.full(800, 0.5, dtype=np.float32)
    out = _pad_to_length(part, 800)
    assert out is part


def test_pad_to_length_zero_target_returns_input() -> None:
    """No reference clock (target=0) means no padding — return as-is."""
    part = np.full(200, 0.5, dtype=np.float32)
    out = _pad_to_length(part, 0)
    assert out is part


def test_pad_to_length_empty_input_becomes_full_silence() -> None:
    """When the system buffer was empty this tick, pad fully fills with silence
    so the per-source WAV stays frame-aligned with the mic clock."""
    part = np.zeros(0, dtype=np.float32)
    out = _pad_to_length(part, 800)
    assert out.shape == (800,)
    assert np.allclose(out, 0.0)


def test_emit_aligned_pair_shares_now_and_pads_system() -> None:
    """Both writes in a tick share one ``now`` and system is padded to mic length."""
    from datetime import datetime
    from pathlib import Path

    from huske.capture.coordinator import CaptureCoordinator
    from huske.config import RuntimeConfig

    calls: list[dict] = []

    class _FakeSink:
        def write_block(self, block, source="microphone", now=None):
            calls.append({"source": source, "frames": int(block.shape[0]), "now": now})

    cfg = RuntimeConfig(
        output_root=Path("/tmp/_huske_test_unused"),
        audio_root=Path("/tmp/_huske_test_unused"),
        logs_root=Path("/tmp/_huske_test_unused"),
        sample_rate=16000,
    )
    coord = CaptureCoordinator(cfg=cfg, mic_device_index=None, sink=_FakeSink())
    coord._sys_active = True  # simulate system source live for this tick
    mic = np.full(800, 0.1, dtype=np.float32)
    sys = np.full(200, 0.2, dtype=np.float32)
    coord._emit_aligned_pair(mic, sys)

    assert len(calls) == 2
    mic_call, sys_call = calls
    assert mic_call["source"] == "microphone"
    assert sys_call["source"] == "system"
    assert mic_call["frames"] == 800
    assert sys_call["frames"] == 800  # padded to mic length
    assert mic_call["now"] is sys_call["now"]
    assert isinstance(mic_call["now"], datetime)


def test_emit_aligned_pair_skips_system_when_inactive() -> None:
    """If system audio never started, only the mic write fires."""
    from pathlib import Path

    from huske.capture.coordinator import CaptureCoordinator
    from huske.config import RuntimeConfig

    calls: list[dict] = []

    class _FakeSink:
        def write_block(self, block, source="microphone", now=None):
            calls.append({"source": source, "frames": int(block.shape[0])})

    cfg = RuntimeConfig(
        output_root=Path("/tmp/_huske_test_unused"),
        audio_root=Path("/tmp/_huske_test_unused"),
        logs_root=Path("/tmp/_huske_test_unused"),
        sample_rate=16000,
    )
    coord = CaptureCoordinator(cfg=cfg, mic_device_index=None, sink=_FakeSink())
    # _sys_active stays False (default — system not started)
    mic = np.full(800, 0.1, dtype=np.float32)
    sys = np.zeros(0, dtype=np.float32)
    coord._emit_aligned_pair(mic, sys)

    assert len(calls) == 1
    assert calls[0]["source"] == "microphone"


def test_pause_skips_emits_until_resume() -> None:
    from pathlib import Path

    from huske.capture.coordinator import CaptureCoordinator
    from huske.config import RuntimeConfig

    calls: list[dict] = []

    class _FakeSink:
        def write_block(self, block, source="microphone", now=None):
            calls.append({"source": source, "frames": int(block.shape[0])})

    cfg = RuntimeConfig(
        output_root=Path("/tmp/_huske_test_unused"),
        audio_root=Path("/tmp/_huske_test_unused"),
        logs_root=Path("/tmp/_huske_test_unused"),
        sample_rate=16000,
    )
    coord = CaptureCoordinator(cfg=cfg, mic_device_index=None, sink=_FakeSink())
    mic = np.full(800, 0.1, dtype=np.float32)

    coord.pause()
    coord._emit_aligned_pair(mic, np.zeros(0, dtype=np.float32))
    assert calls == []

    coord.resume()
    coord._emit_aligned_pair(mic, np.zeros(0, dtype=np.float32))
    assert calls == [{"source": "microphone", "frames": 800}]


def test_pause_waits_for_inflight_emit_before_returning() -> None:
    from pathlib import Path

    from huske.capture.coordinator import CaptureCoordinator
    from huske.config import RuntimeConfig

    entered_write = threading.Event()
    release_write = threading.Event()
    pause_started = threading.Event()
    pause_done = threading.Event()
    errors: list[BaseException] = []
    calls: list[dict] = []

    class _BlockingSink:
        def write_block(self, block, source="microphone", now=None):
            entered_write.set()
            if not release_write.wait(timeout=2.0):
                raise AssertionError("timed out waiting to release write")
            calls.append({"source": source, "frames": int(block.shape[0])})

    cfg = RuntimeConfig(
        output_root=Path("/tmp/_huske_test_unused"),
        audio_root=Path("/tmp/_huske_test_unused"),
        logs_root=Path("/tmp/_huske_test_unused"),
        sample_rate=16000,
    )
    coord = CaptureCoordinator(cfg=cfg, mic_device_index=None, sink=_BlockingSink())
    mic = np.full(800, 0.1, dtype=np.float32)

    def emit() -> None:
        try:
            coord._emit_aligned_pair(mic, np.zeros(0, dtype=np.float32))
        except BaseException as exc:
            errors.append(exc)

    def pause() -> None:
        pause_started.set()
        coord.pause()
        pause_done.set()

    emit_thread = threading.Thread(target=emit)
    emit_thread.start()
    assert entered_write.wait(timeout=1.0)

    pause_thread = threading.Thread(target=pause)
    pause_thread.start()
    assert pause_started.wait(timeout=1.0)
    assert not pause_done.wait(timeout=0.05)

    release_write.set()
    emit_thread.join(timeout=1.0)
    pause_thread.join(timeout=1.0)

    assert not emit_thread.is_alive()
    assert not pause_thread.is_alive()
    assert errors == []
    assert pause_done.is_set()
    assert coord.paused
    assert calls == [{"source": "microphone", "frames": 800}]


def test_mic_callback_discards_audio_while_paused() -> None:
    from pathlib import Path

    from huske.capture.coordinator import CaptureCoordinator
    from huske.config import RuntimeConfig

    class _FakeSink:
        def write_block(self, block, source="microphone", now=None):
            raise AssertionError("paused coordinator should not write")

    cfg = RuntimeConfig(
        output_root=Path("/tmp/_huske_test_unused"),
        audio_root=Path("/tmp/_huske_test_unused"),
        logs_root=Path("/tmp/_huske_test_unused"),
        sample_rate=16000,
    )
    coord = CaptureCoordinator(cfg=cfg, mic_device_index=None, sink=_FakeSink())
    coord.pause()
    coord._mic_callback(np.full((128, 1), 0.8, dtype=np.float32), 128, None, object())

    assert coord._mic_buf.available == 0
    assert coord.peak_levels_db() == (-120.0, -120.0)
