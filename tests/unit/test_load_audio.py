"""Streaming 16 kHz loader."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import soundfile as sf

from huske.transcribe.engines.base import TARGET_SAMPLE_RATE, load_mono_16k


def test_load_mono_16k_streams_48k_stereo_to_same_result(tmp_path: Path) -> None:
    sr = 48_000
    t = np.linspace(0, 0.4, int(sr * 0.4), endpoint=False)
    left = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    right = (0.1 * np.sin(2 * np.pi * 330 * t)).astype(np.float32)
    stereo = np.stack([left, right], axis=1)
    path = tmp_path / "clip.wav"
    sf.write(str(path), stereo, sr, subtype="PCM_16")

    got = load_mono_16k(str(path))

    import soxr

    data, file_sr = sf.read(str(path), dtype="float32", always_2d=False)
    assert file_sr == sr
    mono = data.mean(axis=1)
    expected = soxr.resample(mono, sr, TARGET_SAMPLE_RATE)
    assert got.dtype == np.float32
    assert got.ndim == 1
    # Streaming vs one-shot can differ by a few samples at the tail.
    n = min(len(got), len(expected))
    assert n > TARGET_SAMPLE_RATE * 0.3
    err = float(np.max(np.abs(got[:n] - expected[:n])))
    assert err < 1e-3


def test_load_mono_16k_empty_file(tmp_path: Path) -> None:
    path = tmp_path / "empty.wav"
    sf.write(str(path), np.zeros(0, dtype=np.float32), TARGET_SAMPLE_RATE)
    assert load_mono_16k(str(path)).size == 0
