"""End-to-end test that exercises the actual mlx-whisper worker.

Marked as integration; downloads the `tiny` mlx-whisper model on first run.
Apple Silicon only — skipped on other platforms.
"""

from __future__ import annotations

import platform
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from huske.config import RuntimeConfig
from huske.models import AudioChunk
from huske.transcribe.worker import TranscriptionWorker, chunk_to_job

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        sys.platform != "darwin" or platform.machine() != "arm64",
        reason="mlx-whisper requires Apple Silicon",
    ),
]


def _generate_speechlike_wav(path: Path, seconds: float = 1.5, sr: int = 16000) -> None:
    """Write a deterministic noise signal — Whisper will detect 'no speech' on noise.

    We're testing the *plumbing*, not transcription accuracy.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    t = np.arange(int(sr * seconds)) / sr
    # Sweep + tone — produces no useful speech but exercises the model.
    sig = (0.05 * np.sin(2 * np.pi * 220 * t) + 0.02 * np.sin(2 * np.pi * 660 * t)).astype(
        np.float32
    )
    sf.write(str(path), sig, sr, subtype="PCM_16")


def test_worker_round_trip_with_tiny_model(tmp_path: Path) -> None:
    cfg = RuntimeConfig(
        asr_engine="whisper",
        model="tiny",
        compute_type="int8",
        device="cpu",
        chunk_minutes=15.0,
        output_root=tmp_path / "transcripts",
        audio_root=tmp_path / "audio",
        logs_root=tmp_path / "logs",
        sample_rate=16000,
        channels=1,
        keep_audio=False,
    )
    cfg.output_root.mkdir(parents=True, exist_ok=True)
    cfg.audio_root.mkdir(parents=True, exist_ok=True)

    audio_path = cfg.audio_root / "session_test" / "0001_091500.wav"
    _generate_speechlike_wav(audio_path, seconds=1.5)

    chunk = AudioChunk(
        chunk_seq=1,
        session_id="20260507T091500_aaaa1111",
        start_time=datetime(2026, 5, 7, 9, 15, 0).astimezone(),
        end_time=datetime(2026, 5, 7, 9, 15, 1, 500000).astimezone(),
        expected_duration_seconds=900.0,
        actual_duration_seconds=1.5,
        audio_path=audio_path,
        audio_sources=["microphone"],
    )

    worker = TranscriptionWorker()
    worker.start()
    try:
        worker.submit(chunk_to_job(chunk, cfg))
        # Wait up to 180s for the model to download + load + transcribe.
        deadline = time.monotonic() + 180.0
        result = None
        while time.monotonic() < deadline:
            result = worker.poll_result(timeout=1.0)
            if result is not None:
                break
        assert result is not None, "worker did not return a result within 180s"
        assert result["ok"], f"worker failed: {result.get('error')}"
        transcript_path = Path(result["transcript_path"])
        assert transcript_path.exists()
        body = transcript_path.read_text(encoding="utf-8")
        assert body.startswith("---\n")
        assert "model: mlx-whisper:tiny" in body
        # Audio should have been deleted (keep_audio=False).
        assert not audio_path.exists()
    finally:
        worker.stop(drain_timeout=10.0)
