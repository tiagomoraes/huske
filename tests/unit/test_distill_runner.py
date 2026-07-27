"""`huske distill` backfill: writes sidecars, skips unchanged, preflights the daemon."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

from huske.distill import client as client_mod
from huske.distill.runner import run_distill
from huske.distill.sidecar import read_sidecar
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _write_transcript(output_root: Path) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {"start": 0.0, "end": 4.0, "text": "We approved the budget. Roadmap ships Friday.", "source": "system"},
    ]
    body = body_from_source_segments(start, segs)
    t = build_transcript_from_segments(
        session_id="20260507T093000_abcd1234",
        chunk_seq=1,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["system"],
        model="mlx-whisper:base",
        language="en",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day = output_root / "2026-05-07"
    day.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day / "093000_abcd1234_001.md")


def test_backfill_writes_then_skips(tmp_path: Path) -> None:
    out = tmp_path / "transcripts"
    transcript = _write_transcript(out)
    overrides = {"output_root": out, "distill_model": "heuristic"}

    assert run_distill(cli_overrides=overrides, low_impact=False) == 0
    sidecar = read_sidecar(transcript)
    assert sidecar is not None and sidecar.statements

    # Re-run: the transcript is unchanged, so it's skipped (still exit 0).
    assert run_distill(cli_overrides=overrides, low_impact=False) == 0


def test_preflight_fails_when_daemon_unreachable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_transcript(tmp_path / "transcripts")

    def boom(self: object) -> list[str]:
        raise client_mod.DistillError("connection refused")

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", boom)
    rc = run_distill(
        cli_overrides={
            "output_root": tmp_path / "transcripts",
            # Pin the daemon backend: this test is about the *Ollama* preflight
            # (the default backend is the built-in mlx runtime, which needs no
            # daemon and would happily proceed).
            "distill_backend": "ollama",
            "distill_model": "qwen3.5:0.8b",
        },
        low_impact=False,
    )
    assert rc == 1  # aborts before touching transcripts
