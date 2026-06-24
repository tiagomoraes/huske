"""Tests for the energy-based voice-activity detector."""

from __future__ import annotations

import numpy as np

from huske.capture.vad import EnergyVAD


def _blocks(audio: np.ndarray, sr: int, block_s: float) -> list[np.ndarray]:
    n = max(1, round(sr * block_s))
    return [audio[i : i + n] for i in range(0, len(audio) - n + 1, n)]


def _speech_fraction(audio: np.ndarray, sr: int = 48000, block_s: float = 0.05) -> float:
    vad = EnergyVAD(block_seconds=block_s)
    flags = [vad.is_speech(b) for b in _blocks(audio, sr, block_s)]
    return sum(flags) / len(flags) if flags else 0.0


def test_silence_is_not_speech() -> None:
    sr = 48000
    silence = np.zeros(sr * 3, dtype=np.float32)
    assert _speech_fraction(silence, sr) == 0.0


def test_low_level_noise_is_not_speech() -> None:
    sr = 48000
    rng = np.random.default_rng(0)
    noise = (rng.standard_normal(sr * 3) * 0.002).astype(np.float32)
    # A faint, steady noise floor must not register as speech (it would keep a
    # chunk open forever). Allow a tiny transient at the very start.
    assert _speech_fraction(noise, sr) < 0.05


def test_tone_burst_is_speech() -> None:
    sr = 48000
    t = np.arange(sr * 2, dtype=np.float32) / sr
    tone = (0.2 * np.sin(2 * np.pi * 200 * t)).astype(np.float32)
    assert _speech_fraction(tone, sr) > 0.9


def test_detects_silence_gap_between_speech() -> None:
    sr = 48000
    block_s = 0.05
    t = np.arange(sr, dtype=np.float32) / sr
    tone = (0.2 * np.sin(2 * np.pi * 200 * t)).astype(np.float32)
    gap = np.zeros(sr * 3, dtype=np.float32)  # 3 s of silence
    audio = np.concatenate([tone, gap, tone])

    vad = EnergyVAD(block_seconds=block_s, hangover_seconds=0.3)
    flags = [vad.is_speech(b) for b in _blocks(audio, sr, block_s)]

    # Longest run of non-speech should approximate the 3 s gap.
    longest = cur = 0
    for f in flags:
        cur = 0 if f else cur + 1
        longest = max(longest, cur)
    assert 2.0 <= longest * block_s <= 3.5


def test_hangover_bridges_micro_gaps() -> None:
    # A short inter-word gap (< hangover) stays "speech" so words aren't chopped.
    sr = 48000
    block_s = 0.05
    vad = EnergyVAD(block_seconds=block_s, hangover_seconds=0.4)
    t = np.arange(sr // 2, dtype=np.float32) / sr
    tone = (0.2 * np.sin(2 * np.pi * 200 * t)).astype(np.float32)
    for b in _blocks(tone, sr, block_s):
        vad.is_speech(b)
    # One 0.2 s silent block right after speech — within the hangover window.
    short_gap = np.zeros(round(sr * 0.2), dtype=np.float32)
    assert vad.is_speech(short_gap) is True
