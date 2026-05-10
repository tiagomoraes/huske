"""Integration test for ScreenCaptureKit-based system audio capture.

Skipped automatically if Screen Recording permission isn't granted (e.g., on
CI). On a developer machine with permission granted, captures 1 second and
verifies a non-empty mono float32 stream came back.
"""

from __future__ import annotations

import sys
import time

import numpy as np
import pytest

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only"),
]


def test_system_audio_capture_returns_data() -> None:
    pytest.importorskip("ScreenCaptureKit", reason="pyobjc-framework-ScreenCaptureKit not installed")
    from huske.capture.system_audio import (
        SystemAudioStream,
        check_permission,
    )

    if not check_permission(timeout=5.0):
        pytest.skip("Screen Recording permission not granted to this Python.")

    events: list[tuple[str, str]] = []

    def on_event(severity: str, message: str) -> None:
        events.append((severity, message))

    stream = SystemAudioStream(sample_rate=48000, on_event=on_event)
    stream.start()
    try:
        time.sleep(1.0)
    finally:
        stream.stop()

    blocks = stream.drain_available()
    assert len(blocks) > 0, "no audio buffers received"
    total_samples = sum(b[0].shape[0] for b in blocks)
    # A full second at 48 kHz = 48000 samples. Allow generous tolerance for
    # startup/teardown — at least a third of a second's worth.
    assert total_samples >= 48000 // 3, f"too few samples: {total_samples}"
    # Every block is mono float32.
    for block, _ts in blocks:
        assert block.dtype == np.float32
        assert block.ndim == 1
