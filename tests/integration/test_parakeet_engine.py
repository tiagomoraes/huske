"""End-to-end tests for the Parakeet engine and echo de-duplication.

Marked integration; Apple Silicon + parakeet-mlx + the v3 model are required
(the model downloads on first run). Speech tests additionally need macOS `say`
to synthesize audio and are skipped otherwise.
"""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        sys.platform != "darwin" or platform.machine() != "arm64",
        reason="parakeet-mlx requires Apple Silicon",
    ),
]


def _require_parakeet() -> None:
    pytest.importorskip("parakeet_mlx")


def _say_wav(path: Path, text: str, voice: str = "Luciana", sr: int = 48000) -> None:
    """Synthesize ``text`` to a mono WAV at ``sr`` via macOS ``say`` + ffmpeg."""
    if shutil.which("say") is None or shutil.which("ffmpeg") is None:
        pytest.skip("macOS `say` and ffmpeg required for speech audio")
    path.parent.mkdir(parents=True, exist_ok=True)
    aiff = path.with_suffix(".aiff")
    try:
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    except subprocess.CalledProcessError:
        subprocess.run(["say", "-o", str(aiff), text], check=True)  # default voice
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff),
         "-ar", str(sr), "-ac", "1", str(path)],
        check=True,
    )


def test_parakeet_emits_nothing_on_silence(tmp_path: Path) -> None:
    """The headline fix: Parakeet does not hallucinate text on silence."""
    _require_parakeet()
    from huske.transcribe.engines.parakeet import ParakeetEngine

    sil = tmp_path / "silence.wav"
    sf.write(str(sil), np.zeros(48000 * 5, dtype=np.float32), 48000, subtype="PCM_16")

    engine = ParakeetEngine()
    assert engine.transcribe(str(sil)) == []


def test_parakeet_transcribes_portuguese(tmp_path: Path) -> None:
    _require_parakeet()
    from huske.transcribe.engines.parakeet import ParakeetEngine

    wav = tmp_path / "speech.wav"
    _say_wav(wav, "A reunião de hoje foi muito produtiva e terminamos no horário.")

    engine = ParakeetEngine()
    segments = engine.transcribe(str(wav))
    assert segments, "expected at least one transcribed segment"
    text = " ".join(s.text for s in segments).lower()
    assert "reunião" in text
    # Time-ordered, with sane offsets and confidence.
    assert all(s.end >= s.start >= 0.0 for s in segments)
    assert engine.model_label.startswith("parakeet:")


def test_worker_drops_mic_echo_of_system(tmp_path: Path) -> None:
    """Full worker path: speaker bleed on the mic is removed; both real lines stay."""
    _require_parakeet()
    from huske.transcribe.worker import TranscriptionWorker

    phrase = "De acordo com a sua agenda você tem uma reunião às onze horas."
    human = "Quais são as próximas reuniões que eu tenho hoje?"

    # System channel: leading silence (while the human talks) + the system line.
    sys_only = tmp_path / "sys_only.wav"
    _say_wav(sys_only, phrase)
    sys_data, sr = sf.read(str(sys_only), dtype="float32")
    system_channel = np.concatenate([np.zeros(int(sr * 3), dtype=np.float32), sys_data])
    sys_path = tmp_path / "work" / "system.wav"
    sys_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(sys_path), system_channel, sr, subtype="PCM_16")

    # Mic channel: the human, a gap, then a quieter echo of the system line.
    human_wav = tmp_path / "human.wav"
    _say_wav(human_wav, human)
    human_data, _ = sf.read(str(human_wav), dtype="float32")
    echo = (sys_data * 0.45).astype(np.float32)
    mic = np.concatenate(
        [human_data, np.zeros(int(sr * 1), dtype=np.float32), echo]
    )
    mic_path = tmp_path / "work" / "microphone.wav"
    sf.write(str(mic_path), mic, sr, subtype="PCM_16")

    now = datetime(2026, 6, 24, 10, 0, 0).astimezone()
    job = {
        "chunk_seq": 1,
        "session_id": "20260624T100000_test",
        "audio_paths": {"microphone": str(mic_path), "system": str(sys_path)},
        "start_time": now.isoformat(),
        "end_time": now.isoformat(),
        "expected_duration_seconds": 12.0,
        "actual_duration_seconds": 12.0,
        "gap_seconds": 0.0,
        "audio_sources": ["microphone", "system"],
        "incomplete": False,
        "output_root": str(tmp_path / "out"),
        "asr_engine": "parakeet",
        "config_model": "base",
        "parakeet_model": "mlx-community/parakeet-tdt-0.6b-v3",
        "config_compute_type": "int8",
        "config_device": "auto",
        "language": "pt",
        "echo_dedup": "drop",
        "keep_audio": False,
        "keep_audio_format": "wav",
        "whisper_idle_unload": False,
        "whisper_idle_unload_seconds": 120.0,
    }

    worker = TranscriptionWorker()
    worker.start()
    try:
        assert worker.wait_ready(timeout=120.0)
        worker.submit(job)
        result = None
        deadline = time.monotonic() + 120.0
        while time.monotonic() < deadline:
            result = worker.poll_result(timeout=1.0)
            if result is not None:
                break
        assert result is not None and result["ok"], result and result.get("error")
        body = Path(result["transcript_path"]).read_text()
    finally:
        worker.stop(drain_timeout=5.0)

    assert "model: parakeet:tdt-0.6b-v3" in body
    # The system line appears exactly once — on the system channel, not echoed
    # back on the mic.
    assert body.count("· system]") == 1
    agenda_lines = [ln for ln in body.splitlines() if "agenda" in ln.lower()]
    assert len(agenda_lines) == 1
    assert "· system]" in agenda_lines[0]
    # The human's own mic line survives.
    assert "próximas reuniões" in body
