"""Tests for acoustic echo cancellation (huske.transcribe.aec).

Pure-DSP, no model — synthesizes echo with a known room impulse response and
checks the canceller removes it (high ERLE) while preserving the local voice.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import fftconvolve

from huske.transcribe.aec import cancel_echo, erle_db, estimate_delay
from huske.transcribe.engines.base import Segment

SR = 16000


def _rng_speech(seconds: float, seed: int, sr: int = SR) -> np.ndarray:
    """A speech-like band-limited noise burst (deterministic), normalized."""
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(int(seconds * sr)).astype(np.float32)
    # Low-pass to ~3.5 kHz so it reads like voiced energy, not white hiss.
    from scipy.signal import butter, lfilter

    b, a = butter(4, 3500 / (sr / 2))
    x = lfilter(b, a, x).astype(np.float32)
    return (x / (np.sqrt(np.mean(x**2)) + 1e-9) * 0.1).astype(np.float32)


def _rir(gain: float, sr: int = SR) -> np.ndarray:
    rir = np.zeros(int(0.12 * sr), dtype=np.float32)
    d = int(0.008 * sr)
    for off, amp in [(d, 1.0), (d + int(0.02 * sr), 0.4), (d + int(0.05 * sr), 0.2)]:
        rir[off] = amp
    return rir * gain


def test_reduces_echo_only() -> None:
    """System echo with no near-end speech is attenuated.

    Coherence suppression is a reducer, not a perfect canceller (the
    transcript-level dedup removes whatever residual still transcribes), so we
    only require a meaningful reduction here.
    """
    system = _rng_speech(6.0, seed=1)
    echo = fftconvolve(system, _rir(0.7))[: len(system)].astype(np.float32)
    cleaned = cancel_echo(echo, system, SR)
    assert erle_db(echo, cleaned) > 4.0


def test_preserves_near_end_when_no_echo() -> None:
    """Headphones case: mic has only the local voice, uncorrelated with system.

    The filter finds no coherent echo path, so the near-end voice must survive.
    """
    near = _rng_speech(5.0, seed=2)
    system = _rng_speech(5.0, seed=3)  # unrelated — not present in the mic
    cleaned = cancel_echo(near, system, SR)
    n = min(len(near), len(cleaned))
    corr = float(
        np.dot(cleaned[:n], near[:n])
        / (np.linalg.norm(cleaned[:n]) * np.linalg.norm(near[:n]) + 1e-9)
    )
    assert corr > 0.9


def test_double_talk_keeps_near_end() -> None:
    """When local voice and echo overlap, the local voice is retained."""
    near = _rng_speech(6.0, seed=4)
    system = _rng_speech(6.0, seed=5)
    echo = fftconvolve(system, _rir(0.6))[: len(system)].astype(np.float32)
    mic = near + echo
    cleaned = cancel_echo(mic, system, SR)
    n = min(len(near), len(cleaned))
    # Cleaned should resemble the near-end far more than the echo.
    def corr(a: np.ndarray, b: np.ndarray) -> float:
        return float(np.dot(a[:n], b[:n]) / (np.linalg.norm(a[:n]) * np.linalg.norm(b[:n]) + 1e-9))

    assert corr(cleaned, near) > corr(cleaned, echo)
    assert corr(cleaned, near) > 0.6


def test_estimate_delay_finds_offset() -> None:
    system = _rng_speech(4.0, seed=6)
    delay = 200
    near = np.concatenate([np.zeros(delay, dtype=np.float32), system])[: len(system)]
    assert abs(estimate_delay(near, system, SR) - delay) <= 16


def test_estimate_delay_handles_late_system_reference() -> None:
    system = _rng_speech(4.0, seed=9)
    delay = 800
    far = np.concatenate([np.zeros(delay, dtype=np.float32), system])[: len(system)]

    assert abs(estimate_delay(system, far, SR) + delay) <= 16


def test_estimate_delay_uses_later_energetic_window() -> None:
    system = np.concatenate(
        [
            np.zeros(10 * SR, dtype=np.float32),
            _rng_speech(4.0, seed=10),
        ]
    )
    delay = 320
    near = np.concatenate([np.zeros(delay, dtype=np.float32), system])[: len(system)]

    assert abs(estimate_delay(near, system, SR) - delay) <= 16


def test_cancel_echo_handles_late_system_reference() -> None:
    system = _rng_speech(6.0, seed=11)
    echo = fftconvolve(system, _rir(0.7))[: len(system)].astype(np.float32)
    late_by = int(0.25 * SR)
    late_system = np.concatenate(
        [np.zeros(late_by, dtype=np.float32), system]
    )[: len(system)]

    cleaned = cancel_echo(echo, late_system, SR)

    assert erle_db(echo, cleaned) > 4.0


def test_marks_acoustic_echo_segment_without_text_match() -> None:
    from huske.transcribe.aec import mark_acoustic_echoes

    system = _rng_speech(6.0, seed=12)
    echo = fftconvolve(system, _rir(0.8))[: len(system)].astype(np.float32)
    segs = [
        Segment(0.5, 4.5, "garbled words from the noisy mic path", "microphone"),
        Segment(0.5, 4.5, "clean system transcript with different words", "system"),
    ]

    marked = mark_acoustic_echoes(segs, echo, system, SR)

    assert marked == 1
    assert segs[0].echo is True


def test_acoustic_echo_marker_preserves_local_voice() -> None:
    from huske.transcribe.aec import mark_acoustic_echoes

    near = _rng_speech(6.0, seed=13)
    system = _rng_speech(6.0, seed=14)
    echo = fftconvolve(system, _rir(0.25))[: len(system)].astype(np.float32)
    mic = near + echo
    segs = [
        Segment(0.5, 4.5, "local speaker talking over playback", "microphone"),
        Segment(0.5, 4.5, "system playback", "system"),
    ]

    marked = mark_acoustic_echoes(segs, mic, system, SR)

    assert marked == 0
    assert segs[0].echo is False


def test_echo_window_bounds_cap_each_slice() -> None:
    from huske.transcribe.aec import echo_window_bounds

    bounds = echo_window_bounds(30 * SR, SR, window_seconds=8.0, overlap_seconds=2.0)
    assert bounds[0] == (0, 8 * SR)
    assert all(end - start <= 8 * SR for start, end in bounds)
    assert bounds[-1][1] == 30 * SR
    # Overlap means more than 30/8 windows, but far fewer samples than 30 min STFT.
    assert 4 <= len(bounds) <= 8


def test_windowed_cancel_echo_reduces_long_echo() -> None:
    """A 20 s file must still attenuate echo after the STFT is windowed."""
    system = _rng_speech(20.0, seed=20)
    echo = fftconvolve(system, _rir(0.7))[: len(system)].astype(np.float32)
    cleaned = cancel_echo(echo, system, SR)
    assert erle_db(echo, cleaned) > 4.0


def test_mark_acoustic_echo_uses_pre_cleaned_audio() -> None:
    from huske.transcribe.aec import mark_acoustic_echoes

    system = _rng_speech(6.0, seed=21)
    echo = fftconvolve(system, _rir(0.8))[: len(system)].astype(np.float32)
    cleaned = (echo * 0.05).astype(np.float32)
    segs = [
        Segment(0.5, 4.5, "garbled mic", "microphone"),
        Segment(0.5, 4.5, "system line", "system"),
    ]

    marked = mark_acoustic_echoes(segs, echo, system, SR, cleaned_mic=cleaned)

    assert marked == 1
    assert segs[0].echo is True


def test_empty_inputs_are_safe() -> None:
    empty = np.zeros(0, dtype=np.float32)
    assert cancel_echo(empty, _rng_speech(1.0, 7), SR).size == 0
    near = _rng_speech(1.0, 8)
    out = cancel_echo(near, empty, SR)
    assert out.size == near.size
