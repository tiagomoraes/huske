"""End-to-end pipeline test that exercises chunker → writer with a stub transcription.

Avoids invoking the real Whisper model so it stays fast and deterministic.
"""

from __future__ import annotations

import threading
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from huske.chunker.rotator import ChunkRotator
from huske.config import RuntimeConfig
from huske.models import AudioChunk
from huske.output_readme import ensure_output_readme
from huske.transcribe.writer import build_transcript_from_segments, write_transcript

from .conftest import synthetic_block


def _stub_transcribe_and_write(
    cfg: RuntimeConfig, chunk: AudioChunk, fake_text: str = "hello world"
) -> Path:
    transcript = build_transcript_from_segments(
        session_id=chunk.session_id,
        chunk_seq=chunk.chunk_seq,
        start_time=chunk.start_time,
        end_time=chunk.end_time or chunk.start_time + timedelta(seconds=1),
        expected_duration_seconds=chunk.expected_duration_seconds,
        actual_duration_seconds=chunk.actual_duration_seconds or 0.0,
        gap_seconds=0.0,
        audio_sources=list(chunk.audio_sources),
        model="stub:test",
        language="en",
        incomplete=chunk.is_partial,
        text=fake_text,
    )
    day = cfg.output_root / chunk.start_time.date().isoformat()
    day.mkdir(parents=True, exist_ok=True)
    from huske.paths import transcript_filename

    target = day / transcript_filename(chunk).name
    return write_transcript(transcript, target)


def test_full_pipeline_chunker_to_writer(isolated_cfg: RuntimeConfig) -> None:
    """Drive 3 seconds of fake audio through the chunker, write transcripts."""
    cfg = isolated_cfg
    ensure_output_readme(cfg.output_root)
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_8a3f2c19",
        on_finalized=finalized.append,
    )

    start = datetime(2026, 5, 7, 9, 15, 0).astimezone()
    # 30 blocks × 100ms = 3 seconds → 3 full chunks at 1s each.
    for i in range(30):
        rot.write_block(
            synthetic_block(cfg.block_size, cfg.channels),
            now=start + timedelta(seconds=i * 0.1),
        )
    rot.finalize_current(now=start + timedelta(seconds=3.0))

    assert len(finalized) >= 3

    # Each chunk should produce a transcript file.
    written: list[Path] = []
    for ch in finalized:
        path = _stub_transcribe_and_write(cfg, ch, fake_text=f"chunk {ch.chunk_seq}")
        written.append(path)

    # Verify directory layout per contract.
    day_dir = cfg.output_root / "2026-05-07"
    assert day_dir.exists()
    files = sorted(day_dir.glob("*.md"))
    assert len(files) == len(finalized)
    # Sortable filenames = chronological order.
    names = [p.name for p in files]
    assert names == sorted(names)
    # Each name format: HHMMSS_<id>_<seq>.md
    for n in names:
        parts = n.removesuffix(".md").split("_")
        assert len(parts) == 3
        assert len(parts[0]) == 6  # HHMMSS
        assert len(parts[1]) == 8  # session id short
        assert len(parts[2]) == 3  # chunk seq

    # Auto-generated README is present.
    assert (cfg.output_root / "README.md").exists()


def test_graceful_stop_partial_chunk(isolated_cfg: RuntimeConfig) -> None:
    """Stop mid-chunk — partial chunk is finalized with shorter actual_duration."""
    cfg = isolated_cfg
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T091500_8a3f2c19",
        on_finalized=finalized.append,
    )

    start = datetime(2026, 5, 7, 9, 15, 0).astimezone()
    # 6 blocks × 100ms = 0.6 seconds (less than 1-second chunk boundary).
    for i in range(6):
        rot.write_block(
            synthetic_block(cfg.block_size, cfg.channels),
            now=start + timedelta(seconds=i * 0.1),
        )
    rot.finalize_current(now=start + timedelta(seconds=0.6))

    assert len(finalized) == 1
    chunk = finalized[0]
    assert chunk.is_partial
    assert chunk.actual_duration_seconds is not None
    assert 0.5 <= chunk.actual_duration_seconds <= 0.7

    written = _stub_transcribe_and_write(cfg, chunk, fake_text="partial")
    assert written.exists()
    body = written.read_text(encoding="utf-8")
    assert "incomplete: true" in body
    # Frontmatter shows actual < expected.
    assert "duration_actual_seconds" in body


def test_cross_day_chunks_filed_under_start_date(isolated_cfg: RuntimeConfig) -> None:
    """Chunk that starts at 23:59 stays in that day's folder even if it would close after midnight."""
    cfg = isolated_cfg
    finalized: list[AudioChunk] = []
    rot = ChunkRotator(
        cfg=cfg,
        session_id="20260507T235900_aaaa1111",
        on_finalized=finalized.append,
    )

    # Start at 23:59:30 on day 1, write 90 seconds of audio crossing midnight.
    start = datetime(2026, 5, 7, 23, 59, 30).astimezone()
    for i in range(900):  # 90 seconds at 100ms blocks → 90 chunks of 1s
        rot.write_block(
            synthetic_block(cfg.block_size, cfg.channels),
            now=start + timedelta(seconds=i * 0.1),
        )
    rot.finalize_current(now=start + timedelta(seconds=90))

    # Write all transcripts.
    for ch in finalized:
        _stub_transcribe_and_write(cfg, ch, fake_text=f"chunk {ch.chunk_seq}")

    # Both day folders exist.
    day1 = cfg.output_root / "2026-05-07"
    day2 = cfg.output_root / "2026-05-08"
    assert day1.exists()
    assert day2.exists()
    # Each chunk filed under its start-time day.
    day1_files = list(day1.glob("*.md"))
    day2_files = list(day2.glob("*.md"))
    assert len(day1_files) >= 1
    assert len(day2_files) >= 1
    # All day1 filenames start with 23 or 00 hours from the date 2026-05-07.
    for p in day1_files:
        hh = p.name[:2]
        assert hh == "23"
    for p in day2_files:
        hh = p.name[:2]
        assert hh == "00"
