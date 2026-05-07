"""Integration test fixtures: fake audio sources, stub transcription, isolated paths."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

from huske.config import RuntimeConfig


@pytest.fixture
def isolated_cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        chunk_minutes=1.0 / 60.0,  # 1-second chunks
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        sample_rate=16000,
        block_size=1600,  # 100 ms blocks
        channels=1,
    )


def synthetic_block(samples: int, channels: int, freq_hz: float = 440.0, sr: int = 16000) -> np.ndarray:
    """A short sine-wave block (helpful for sanity checks)."""
    t = np.arange(samples, dtype=np.float32) / sr
    sig = 0.1 * np.sin(2 * np.pi * freq_hz * t).astype(np.float32)
    return np.tile(sig[:, None], (1, channels))


def silent_block(samples: int, channels: int) -> np.ndarray:
    return np.zeros((samples, channels), dtype=np.float32)
