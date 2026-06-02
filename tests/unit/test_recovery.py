"""Tests for huske.recovery.scanner."""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from huske.config import RuntimeConfig
from huske.recovery.scanner import (
    cleanup_session_dir,
    move_to_incomplete,
    scan_orphans,
)


@pytest.fixture
def cfg(tmp_path: Path) -> RuntimeConfig:
    return RuntimeConfig(
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        sample_rate=8000,
        channels=1,
    )


def _make_wav(path: Path, seconds: float, sr: int = 8000, channels: int = 1) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    n = int(sr * seconds)
    data = np.zeros((n, channels), dtype=np.float32)
    sf.write(str(path), data, sr, subtype="PCM_16")


def test_no_orphans_when_audio_root_missing(cfg: RuntimeConfig) -> None:
    assert scan_orphans(cfg) == []


def test_session_with_dead_lock_is_orphaned(cfg: RuntimeConfig) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_aaaa1111"
    sess_dir.mkdir(parents=True)
    (sess_dir / ".lock").write_text("99999999", encoding="utf-8")  # bogus PID
    _make_wav(sess_dir / "0001_091500.wav", seconds=2.0)

    orphans = scan_orphans(cfg)
    assert len(orphans) == 1
    assert orphans[0].session_id == "20260507T091500_aaaa1111"
    assert len(orphans[0].chunks) == 1
    assert orphans[0].chunks[0].valid


def test_session_with_alive_lock_is_skipped(cfg: RuntimeConfig) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_bbbb2222"
    sess_dir.mkdir(parents=True)
    (sess_dir / ".lock").write_text(str(os.getpid()), encoding="utf-8")
    _make_wav(sess_dir / "0001_091500.wav", seconds=2.0)

    orphans = scan_orphans(cfg)
    assert orphans == []


def test_truncated_wav_is_marked_invalid(cfg: RuntimeConfig) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_cccc3333"
    sess_dir.mkdir(parents=True)
    bad = sess_dir / "0001_091500.wav"
    bad.parent.mkdir(parents=True, exist_ok=True)
    bad.write_bytes(b"not a wav")  # truncated/garbage

    orphans = scan_orphans(cfg)
    assert len(orphans) == 1
    assert not orphans[0].chunks[0].valid


def test_move_to_incomplete(cfg: RuntimeConfig, tmp_path: Path) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_dddd4444"
    sess_dir.mkdir(parents=True)
    bad = sess_dir / "0001_091500.wav"
    bad.write_bytes(b"x")
    moved = move_to_incomplete(cfg, "20260507T091500_dddd4444", bad)
    assert moved.exists()
    assert "incomplete" in str(moved)
    assert not bad.exists()


def test_cleanup_session_dir_removes_empty_dir(cfg: RuntimeConfig) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_eeee5555"
    sess_dir.mkdir(parents=True)
    cleanup_session_dir(sess_dir)
    assert not sess_dir.exists()


def test_cleanup_session_dir_keeps_nonempty(cfg: RuntimeConfig) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_ffff6666"
    sess_dir.mkdir(parents=True)
    (sess_dir / "leftover.wav").write_text("x", encoding="utf-8")
    cleanup_session_dir(sess_dir)
    assert sess_dir.exists()


def test_filename_outside_pattern_is_ignored(cfg: RuntimeConfig) -> None:
    sess_dir = cfg.audio_root / "20260507T091500_aaaa9999"
    sess_dir.mkdir(parents=True)
    # Stale lock so the session is recognized; weird filename is the noise we ignore.
    (sess_dir / ".lock").write_text("99999999", encoding="utf-8")
    (sess_dir / "weird.wav").write_text("x", encoding="utf-8")
    orphans = scan_orphans(cfg)
    assert len(orphans) == 1
    assert orphans[0].chunks == []


def test_already_transcribed_chunks_are_skipped_and_wav_removed(cfg: RuntimeConfig) -> None:
    """If a transcript file already exists for a chunk, the orphan WAV is auto-cleaned."""
    sess_dir = cfg.audio_root / "20260507T091500_abcd1234"
    sess_dir.mkdir(parents=True)
    (sess_dir / ".lock").write_text("99999999", encoding="utf-8")
    wav = sess_dir / "0001_091500.wav"
    _make_wav(wav, seconds=2.0)

    # Pre-existing transcript for chunk 1 (matches sid_short=abcd1234, seq=001).
    day = cfg.output_root / "2026-05-07"
    day.mkdir(parents=True)
    (day / "091500_abcd1234_001.md").write_text("---\nfoo: bar\n---\n", encoding="utf-8")

    orphans = scan_orphans(cfg)
    # WAV was removed; the orphan session has no chunks but is still reported (lock present).
    assert not wav.exists()
    assert len(orphans) == 1
    assert orphans[0].chunks == []


def test_per_source_wavs_grouped_into_one_chunk(cfg: RuntimeConfig) -> None:
    """A chunk's mic + system WAVs collapse into one OrphanChunk with both paths."""
    sess_dir = cfg.audio_root / "20260507T091500_aaaa1111"
    sess_dir.mkdir(parents=True)
    (sess_dir / ".lock").write_text("99999999", encoding="utf-8")
    mic = sess_dir / "0001_091500_microphone.wav"
    sys_ = sess_dir / "0001_091500_system.wav"
    _make_wav(mic, seconds=2.0)
    _make_wav(sys_, seconds=2.0)

    orphans = scan_orphans(cfg)
    assert len(orphans) == 1
    assert len(orphans[0].chunks) == 1
    chunk = orphans[0].chunks[0]
    assert chunk.valid
    assert set(chunk.audio_paths.keys()) == {"microphone", "system"}
    assert chunk.invalid_paths == []


def test_per_source_invalid_sibling_separated(cfg: RuntimeConfig) -> None:
    """If one source's WAV is truncated, the chunk stays valid via the other source."""
    sess_dir = cfg.audio_root / "20260507T091500_bbbb2222"
    sess_dir.mkdir(parents=True)
    (sess_dir / ".lock").write_text("99999999", encoding="utf-8")
    mic = sess_dir / "0001_091500_microphone.wav"
    sys_ = sess_dir / "0001_091500_system.wav"
    _make_wav(mic, seconds=2.0)
    sys_.write_bytes(b"truncated")

    orphans = scan_orphans(cfg)
    chunk = orphans[0].chunks[0]
    assert chunk.valid
    assert list(chunk.audio_paths.keys()) == ["microphone"]
    assert chunk.invalid_paths == [sys_]


def test_legacy_unsuffixed_wav_recovers_as_microphone(cfg: RuntimeConfig) -> None:
    """Sessions captured before the source-split change still recover."""
    sess_dir = cfg.audio_root / "20260507T091500_cccc3333"
    sess_dir.mkdir(parents=True)
    (sess_dir / ".lock").write_text("99999999", encoding="utf-8")
    wav = sess_dir / "0001_091500.wav"
    _make_wav(wav, seconds=2.0)

    orphans = scan_orphans(cfg)
    chunk = orphans[0].chunks[0]
    assert chunk.valid
    assert list(chunk.audio_paths.keys()) == ["microphone"]
    assert chunk.audio_paths["microphone"] == wav
