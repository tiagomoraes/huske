"""Tests for the transcription worker process wrapper."""

from __future__ import annotations

import os
import signal
import time
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

from huske.transcribe import worker


def _sigint_ignoring_child(ready_q: Any) -> None:
    worker._configure_worker_signal_handlers()
    ready_q.put(os.getpid())
    time.sleep(5.0)


def test_worker_child_ignores_sigint_until_parent_stops_it() -> None:
    ready_q: Any = worker._ctx.Queue()
    proc: Any = worker._ctx.Process(target=_sigint_ignoring_child, args=(ready_q,))
    proc.start()
    try:
        pid = ready_q.get(timeout=5.0)
        os.kill(pid, signal.SIGINT)

        proc.join(timeout=0.75)

        assert proc.is_alive()
    finally:
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=2.0)
        if proc.is_alive():
            proc.kill()
            proc.join(timeout=2.0)
        try:
            ready_q.cancel_join_thread()
        except (OSError, ValueError):
            pass
        try:
            ready_q.close()
        except (OSError, ValueError):
            pass


def test_audio_energy_gate_rejects_low_level_noise(tmp_path: Path) -> None:
    path = tmp_path / "noise.wav"
    sr = 16_000
    audio = np.full(sr * 2, 0.0005, dtype=np.float32)
    sf.write(path, audio, sr)

    gate = worker._AudioEnergyGate.from_path(str(path))

    assert not gate.has_signal(0.5, 1.0)


def test_audio_energy_gate_accepts_speech_above_noise_floor(tmp_path: Path) -> None:
    path = tmp_path / "speech.wav"
    sr = 16_000
    audio = np.full(sr * 2, 0.0005, dtype=np.float32)
    start = int(0.8 * sr)
    end = int(1.2 * sr)
    t = np.arange(end - start, dtype=np.float32) / sr
    audio[start:end] += (0.02 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    sf.write(path, audio, sr)

    gate = worker._AudioEnergyGate.from_path(str(path))

    assert gate.has_signal(0.9, 1.1)
    assert not gate.has_signal(0.1, 0.2)


def test_audio_energy_gate_keeps_continuous_speech_like_audio(tmp_path: Path) -> None:
    path = tmp_path / "continuous.wav"
    sr = 16_000
    t = np.arange(sr * 2, dtype=np.float32) / sr
    audio = (0.02 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    sf.write(path, audio, sr)

    gate = worker._AudioEnergyGate.from_path(str(path))

    assert gate.has_signal(0.5, 1.0)
