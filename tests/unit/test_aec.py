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


# --- WebRTC AEC3 -------------------------------------------------------------

import pytest  # noqa: E402

from huske.transcribe.aec import (  # noqa: E402
    cancel_echo_webrtc,
    remove_echo,
    webrtc_aec_available,
)

needs_webrtc = pytest.mark.skipif(
    not webrtc_aec_available(), reason="livekit (WebRTC AEC3) not installed"
)


def _speaker_echo(system: np.ndarray, gain: float = 0.5, delay_ms: float = 30.0) -> np.ndarray:
    """System audio as the mic hears it from the laptop speakers."""
    echo = fftconvolve(np.tanh(3 * system) / 3, _rir(gain))[: len(system)].astype(np.float32)
    d = int(delay_ms * SR / 1000)
    return np.concatenate([np.zeros(d, dtype=np.float32), echo])[: len(system)]


def _corr(a: np.ndarray, b: np.ndarray) -> float:
    n = min(len(a), len(b))
    return float(np.dot(a[:n], b[:n]) / (np.linalg.norm(a[:n]) * np.linalg.norm(b[:n]) + 1e-9))


@needs_webrtc
def test_webrtc_removes_echo_only() -> None:
    """Remote voice on speakers with nobody talking locally: the mic copy goes."""
    system = _rng_speech(8.0, seed=21)
    echo = _speaker_echo(system)
    cleaned = cancel_echo_webrtc(echo, system, SR)
    assert cleaned.shape == echo.shape
    # Skip the first second of convergence.
    assert erle_db(echo[SR:], cleaned[SR:]) > 20.0


@needs_webrtc
def test_webrtc_is_transparent_with_headphones() -> None:
    """No echo path: the local voice passes, time-aligned, at full level."""
    near = _rng_speech(6.0, seed=22)
    system = _rng_speech(6.0, seed=23)
    cleaned = cancel_echo_webrtc(near, system, SR)
    level_db = 10 * np.log10(np.mean(cleaned**2) / np.mean(near**2))
    assert abs(level_db) < 3.0
    # Same time base as the input (the canceller's 8 ms latency is undone).
    c = np.correlate(cleaned[SR : 3 * SR], near[SR : 3 * SR], mode="full")
    lag = int(np.argmax(np.abs(c))) - (2 * SR - 1)
    assert abs(lag) <= 2


@needs_webrtc
def test_webrtc_double_talk_keeps_local_voice() -> None:
    near = np.concatenate([np.zeros(3 * SR, np.float32), _rng_speech(5.0, seed=24)])
    system = _rng_speech(8.0, seed=25)
    echo = _speaker_echo(system)
    mic = near + echo
    cleaned = cancel_echo_webrtc(mic, system, SR)
    # Echo-only stretch (after convergence) is removed …
    assert erle_db(mic[SR : 3 * SR], cleaned[SR : 3 * SR]) > 15.0
    # … while the double-talk stretch keeps the local voice's energy and shape.
    dt = slice(3 * SR, 8 * SR)
    level_db = 10 * np.log10(np.mean(cleaned[dt] ** 2) / np.mean(near[dt] ** 2))
    assert level_db > -6.0
    assert _corr(cleaned[dt], near[dt]) > _corr(cleaned[dt], echo[dt])


@needs_webrtc
@pytest.mark.parametrize("ref_offset_ms", [-300.0, 600.0])
def test_webrtc_realigns_late_or_early_reference(ref_offset_ms: float) -> None:
    """Independent-clock captures: the saved reference can be late or early."""
    system = _rng_speech(8.0, seed=26)
    echo = _speaker_echo(system)
    s = int(abs(ref_offset_ms) * SR / 1000)
    if ref_offset_ms < 0:  # reference saved late
        ref = np.concatenate([np.zeros(s, np.float32), system])[: len(system)]
    else:  # reference saved early
        ref = np.concatenate([system[s:], np.zeros(s, np.float32)])
    cleaned = cancel_echo_webrtc(echo, ref, SR)
    assert erle_db(echo[SR:], cleaned[SR:]) > 15.0


@needs_webrtc
def test_webrtc_tracks_a_mid_chunk_offset_jump() -> None:
    """An offset that jumps mid-chunk is re-aligned per window."""
    system = _rng_speech(40.0, seed=27)
    echo = _speaker_echo(system)
    jump = int(0.25 * SR)
    half = len(system) // 2
    ref = np.concatenate(
        [system[:half], np.zeros(jump, np.float32), system[half:]]
    )[: len(system)]
    cleaned = cancel_echo_webrtc(echo, ref, SR, window_seconds=10.0)
    for part in (slice(SR, half), slice(half + 5 * SR, len(system))):
        assert erle_db(echo[part], cleaned[part]) > 12.0


@needs_webrtc
@pytest.mark.parametrize("n", [0, 1, 50, 159, 161, 16_001])
def test_webrtc_odd_lengths_are_safe(n: int) -> None:
    """Never hand AEC3 a non-10 ms frame (it would abort the process)."""
    near = _rng_speech(max(n, 1) / SR, seed=28)[:n]
    system = _rng_speech(max(n, 1) / SR, seed=29)[:n]
    out = cancel_echo_webrtc(near, system, SR)
    assert out.shape == near.shape


@needs_webrtc
def test_webrtc_silent_reference_passes_through() -> None:
    near = _rng_speech(2.0, seed=30)
    out = cancel_echo_webrtc(near, np.zeros_like(near), SR)
    assert np.array_equal(out, near)


def test_remove_echo_falls_back_to_coherence(monkeypatch: pytest.MonkeyPatch) -> None:
    import huske.transcribe.aec as aec

    def boom(*_a: object, **_k: object) -> np.ndarray:
        raise ImportError("no livekit")

    monkeypatch.setattr(aec, "cancel_echo_webrtc", boom)
    system = _rng_speech(4.0, seed=31)
    echo = fftconvolve(system, _rir(0.7))[: len(system)].astype(np.float32)
    cleaned, method = remove_echo(echo, system, SR)
    assert method == "coherence"
    assert cleaned.shape == echo.shape
    with pytest.raises(ImportError):
        remove_echo(echo, system, SR, method="webrtc")
    _, method = remove_echo(echo, system, SR, method="coherence")
    assert method == "coherence"
