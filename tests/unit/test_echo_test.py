"""`huske echo-test` analysis, with capture and playback faked."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pytest
from scipy.signal import fftconvolve

from huske.capture import echo_test
from huske.transcribe.aec import webrtc_aec_available

SR = 16000


def _speech(seconds: float, seed: int) -> np.ndarray:
    from scipy.signal import butter, lfilter

    rng = np.random.default_rng(seed)
    x = rng.standard_normal(int(seconds * SR)).astype(np.float32)
    b, a = butter(4, 3500 / (SR / 2))
    x = lfilter(b, a, x).astype(np.float32)
    # Speech-like on/off envelope.
    env = (np.sin(np.linspace(0, 12 * np.pi, x.size)) > -0.2).astype(np.float32)
    return (x / (np.sqrt(np.mean(x**2)) + 1e-9) * 0.1 * env).astype(np.float32)


def _patch(monkeypatch: pytest.MonkeyPatch, mic: np.ndarray, sys_: np.ndarray) -> None:
    monkeypatch.setattr(echo_test, "_tts_clip", lambda path: 6.0)
    monkeypatch.setattr(
        echo_test, "_capture", lambda seconds, play, mic_name: (mic, sys_, "synced", "Test Mic")
    )
    from huske.capture import coreaudio_hal

    monkeypatch.setattr(coreaudio_hal, "default_output_device", lambda: 1)
    monkeypatch.setattr(coreaudio_hal, "device_name", lambda dev: "Test Speakers")


@pytest.mark.skipif(not webrtc_aec_available(), reason="livekit not installed")
def test_reports_cancelled_echo(monkeypatch: pytest.MonkeyPatch) -> None:
    sys_ = _speech(8.0, seed=1)
    rir = np.zeros(int(0.1 * SR), np.float32)
    rir[int(0.02 * SR)] = 0.5
    rir[int(0.05 * SR)] = 0.2
    mic = fftconvolve(sys_, rir)[: len(sys_)].astype(np.float32)
    _patch(monkeypatch, mic, sys_)
    result = echo_test.run_echo_test()
    assert result.echo_present
    assert result.capture_mode == "synced"
    assert result.method == "webrtc"
    assert result.erle_db > 15
    assert result.echo_delay_ms is not None and 10 <= result.echo_delay_ms <= 40
    assert "cancelled" in result.verdict


def test_reports_no_echo_path_with_headphones(monkeypatch: pytest.MonkeyPatch) -> None:
    sys_ = _speech(8.0, seed=2)
    mic = (np.random.default_rng(3).standard_normal(sys_.size) * 1e-4).astype(np.float32)
    _patch(monkeypatch, mic, sys_)
    result = echo_test.run_echo_test()
    assert not result.echo_present
    assert result.echo_delay_ms is None
    assert "No echo path" in result.verdict


def test_silent_system_audio_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    z = np.zeros(SR * 4, np.float32)
    _patch(monkeypatch, z, z)
    with pytest.raises(RuntimeError, match="silent"):
        echo_test.run_echo_test()


def test_temp_clip_is_removed(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[Path] = []

    def fake_capture(seconds: float, play: Path, mic_name: Any) -> Any:
        seen.append(play)
        raise RuntimeError("boom")

    monkeypatch.setattr(echo_test, "_tts_clip", lambda path: 1.0)
    monkeypatch.setattr(echo_test, "_capture", fake_capture)
    with pytest.raises(RuntimeError):
        echo_test.run_echo_test()
    assert seen and not seen[0].exists()
