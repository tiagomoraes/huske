"""Tests for the internal _SourceBuffer in capture/coordinator.py.

These don't touch sounddevice or ScreenCaptureKit — pure buffer logic.
"""

from __future__ import annotations

import threading

import numpy as np
import pytest

from huske.capture.coordinator import _SourceBuffer, _to_db


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
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    def consumer() -> None:
        try:
            for _ in range(200):
                buf.take(20)
        except Exception as exc:  # noqa: BLE001
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
