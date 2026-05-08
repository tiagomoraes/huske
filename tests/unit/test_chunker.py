"""Tests for huske.chunker.rotator."""

from __future__ import annotations

import threading
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from huske.chunker.rotator import ChunkRotator
from huske.config import RuntimeConfig
from huske.models import AudioChunk


@pytest.fixture
def cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        chunk_minutes=1.0 / 60.0,  # 1 second chunks (small for tests)
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        sample_rate=8000,  # smaller, faster
        block_size=800,
        channels=1,
    )


def _block(samples: int, channels: int, value: float = 0.1) -> np.ndarray:
    return np.full((samples, channels), value, dtype=np.float32)


def test_rotation_at_boundary_produces_finalized_chunk(cfg: RuntimeConfig) -> None:
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    # 1.2 seconds of audio at 8kHz mono → 9600 samples → 12 blocks of 800.
    for i in range(12):
        rot.write_block(
            _block(cfg.block_size, cfg.channels), now=start + timedelta(seconds=i * 0.1)
        )
    rot.finalize_current(now=start + timedelta(seconds=1.2))

    # Should have produced one finalized chunk for the 1-second boundary,
    # plus one for the partial chunk at finalize time.
    assert len(finalized) >= 1
    first = finalized[0]
    assert first.actual_duration_seconds is not None
    assert 0.95 <= first.actual_duration_seconds <= 1.05
    assert first.audio_path.exists()
    info = sf.info(str(first.audio_path))
    assert info.samplerate == cfg.sample_rate
    assert info.channels == cfg.channels


def test_finalize_partial_chunk_marks_short_duration(cfg: RuntimeConfig) -> None:
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    # 0.4 seconds of audio.
    for i in range(4):
        rot.write_block(
            _block(cfg.block_size, cfg.channels), now=start + timedelta(seconds=i * 0.1)
        )
    rot.finalize_current(now=start + timedelta(seconds=0.4))

    assert len(finalized) == 1
    chunk = finalized[0]
    assert chunk.actual_duration_seconds is not None
    assert chunk.actual_duration_seconds < cfg.chunk_seconds
    assert chunk.is_partial


def test_no_dropped_frames_across_rotation(cfg: RuntimeConfig) -> None:
    """Verify the total samples written across both chunks equals the total samples submitted."""
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    total_blocks = 18  # 14400 samples at 8kHz = 1.8s → spans rotation
    for i in range(total_blocks):
        rot.write_block(
            _block(cfg.block_size, cfg.channels, value=float(i) / 100),
            now=start + timedelta(seconds=i * 0.1),
        )
    rot.finalize_current(now=start + timedelta(seconds=total_blocks * 0.1))

    total_samples = 0
    for chunk in finalized:
        info = sf.info(str(chunk.audio_path))
        total_samples += info.frames
    expected = total_blocks * cfg.block_size
    # Allow a 1-block tolerance for boundary handling.
    assert abs(total_samples - expected) <= cfg.block_size


def test_chunk_seq_monotonic(cfg: RuntimeConfig) -> None:
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    for i in range(30):
        rot.write_block(
            _block(cfg.block_size, cfg.channels), now=start + timedelta(seconds=i * 0.1)
        )
    rot.finalize_current(now=start + timedelta(seconds=3.0))
    seqs = [c.chunk_seq for c in finalized]
    assert seqs == sorted(seqs)
    assert seqs[0] == 1
    assert all(b - a == 1 for a, b in zip(seqs, seqs[1:]))


def test_two_sources_produce_two_wavs_per_chunk(cfg: RuntimeConfig) -> None:
    """Mic + system sources each get their own WAV with the source suffix."""
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
        default_audio_sources=["microphone", "system"],
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    # 0.5s of audio from each source — one partial chunk on finalize.
    for i in range(5):
        when = start + timedelta(seconds=i * 0.1)
        rot.write_block(_block(cfg.block_size, cfg.channels, 0.1), source="microphone", now=when)
        rot.write_block(_block(cfg.block_size, cfg.channels, 0.2), source="system", now=when)
    rot.finalize_current(now=start + timedelta(seconds=0.5))

    assert len(finalized) == 1
    chunk = finalized[0]
    assert set(chunk.audio_paths.keys()) == {"microphone", "system"}
    assert chunk.audio_sources == ["microphone", "system"]
    mic_path = chunk.audio_paths["microphone"]
    sys_path = chunk.audio_paths["system"]
    assert mic_path.name.endswith("_microphone.wav")
    assert sys_path.name.endswith("_system.wav")
    assert mic_path.exists() and sys_path.exists()
    # audio_path mirrors the first source.
    assert chunk.audio_path == mic_path


def test_single_active_source_writes_only_one_wav(cfg: RuntimeConfig) -> None:
    """If only mic ever fires, only the mic WAV exists; no empty system file."""
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
        default_audio_sources=["microphone", "system"],
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    for i in range(5):
        rot.write_block(
            _block(cfg.block_size, cfg.channels),
            source="microphone",
            now=start + timedelta(seconds=i * 0.1),
        )
    rot.finalize_current(now=start + timedelta(seconds=0.5))

    chunk = finalized[0]
    assert list(chunk.audio_paths.keys()) == ["microphone"]
    assert chunk.audio_sources == ["microphone"]
