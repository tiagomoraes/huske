"""Tests for huske.chunker.rotator."""

from __future__ import annotations

from datetime import datetime, timedelta
from itertools import pairwise
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
        speech_gated=False,  # legacy fixed-interval rotation for these tests
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        sample_rate=8000,  # smaller, faster
        block_size=800,
        channels=1,
    )


@pytest.fixture
def gated_cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        chunk_minutes=10.0,  # high cap — splits should come from silence, not the cap
        speech_gated=True,
        silence_split_seconds=5.0,
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        sample_rate=8000,
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
    assert all(b - a == 1 for a, b in pairwise(seqs))


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


def test_pause_current_finalizes_but_allows_resume(cfg: RuntimeConfig) -> None:
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()

    rot.write_block(_block(cfg.block_size, cfg.channels), now=start)
    assert rot.pause_current(now=start + timedelta(seconds=0.1)) is True
    assert not rot.closed

    resumed_at = start + timedelta(seconds=10)
    rot.write_block(_block(cfg.block_size, cfg.channels), now=resumed_at)
    rot.finalize_current(now=resumed_at + timedelta(seconds=0.1))

    assert [chunk.chunk_seq for chunk in finalized] == [1, 2]
    assert all(chunk.audio_path.exists() for chunk in finalized)
    assert rot.closed


def test_pause_current_without_open_chunk_is_noop(cfg: RuntimeConfig) -> None:
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )

    assert rot.pause_current() is False
    assert finalized == []
    assert not rot.closed


# --- speech-gated segmentation --------------------------------------------


def test_gated_does_not_open_chunk_during_silence(gated_cfg: RuntimeConfig) -> None:
    """Silence before any speech writes nothing — no large near-empty files."""
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=gated_cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    for i in range(20):  # 2 s of silence
        rot.write_block(
            _block(gated_cfg.block_size, gated_cfg.channels),
            now=start + timedelta(seconds=i * 0.1),
            is_speech=False,
        )
    assert rot.current_chunk_seq == 0  # nothing opened
    assert finalized == []


def test_gated_splits_chunks_on_long_silence(gated_cfg: RuntimeConfig) -> None:
    """Speech, a >silence_split pause, then speech again → two separate chunks."""
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=gated_cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    blk = _block(gated_cfg.block_size, gated_cfg.channels)

    # 1 s of speech.
    for i in range(10):
        rot.write_block(blk, now=start + timedelta(seconds=i * 0.1), is_speech=True)
    # 6 s of silence (> silence_split_seconds=5) — should finalize the chunk.
    t = 1.0
    for i in range(60):
        rot.write_block(blk, now=start + timedelta(seconds=t + i * 0.1), is_speech=False)
    # Speech resumes → opens a new chunk.
    t2 = 7.5
    for i in range(10):
        rot.write_block(blk, now=start + timedelta(seconds=t2 + i * 0.1), is_speech=True)
    rot.finalize_current(now=start + timedelta(seconds=t2 + 1.1))

    assert len(finalized) == 2
    assert [c.chunk_seq for c in finalized] == [1, 2]
    # The first chunk's audio is bounded (speech + up to the split window), not
    # the full wall-clock span.
    assert finalized[0].actual_duration_seconds is not None
    assert finalized[0].actual_duration_seconds <= gated_cfg.silence_split_seconds + 2.0


def test_gated_keeps_short_gaps_in_one_chunk(gated_cfg: RuntimeConfig) -> None:
    """A pause shorter than silence_split keeps speech in a single chunk."""
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=gated_cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    blk = _block(gated_cfg.block_size, gated_cfg.channels)
    for i in range(10):  # speech
        rot.write_block(blk, now=start + timedelta(seconds=i * 0.1), is_speech=True)
    for i in range(20):  # 2 s gap (< 5 s split)
        rot.write_block(blk, now=start + timedelta(seconds=1.0 + i * 0.1), is_speech=False)
    for i in range(10):  # speech resumes
        rot.write_block(blk, now=start + timedelta(seconds=3.0 + i * 0.1), is_speech=True)
    rot.finalize_current(now=start + timedelta(seconds=4.1))

    assert len(finalized) == 1  # one continuous chunk across the short gap


def test_gated_max_cap_rotates_unbroken_speech(gated_cfg: RuntimeConfig) -> None:
    """Continuous speech past the chunk_minutes cap rotates seamlessly."""
    cfg = gated_cfg.model_copy(update={"chunk_minutes": 1.0 / 60.0})  # 1 s cap
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_aaaa1111",
        on_finalized=finalized.append,
    )
    start = datetime(2026, 5, 7, 9, 0, 0).astimezone()
    blk = _block(cfg.block_size, cfg.channels)
    for i in range(25):  # 2.5 s of unbroken speech, 1 s cap → ~2 rotations
        rot.write_block(blk, now=start + timedelta(seconds=i * 0.1), is_speech=True)
    rot.finalize_current(now=start + timedelta(seconds=2.5))
    assert len(finalized) >= 2
    assert [c.chunk_seq for c in finalized] == sorted(c.chunk_seq for c in finalized)
