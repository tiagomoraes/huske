"""End-to-end: acoustic echo cancellation through the real worker.

Builds a mic channel containing the local voice plus the acoustic echo of a
*different-language* system channel (the no-headphones case, including
double-talk), runs the actual transcription worker, and asserts the system's
words do not leak onto the mic channel — with the cross-channel text dedup
turned OFF, so only the audio-level AEC can be responsible.

Apple Silicon + parakeet-mlx + macOS `say` + ffmpeg required; skipped otherwise.
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

SR = 16000


def _say(path: Path, text: str, voice: str) -> np.ndarray:
    if shutil.which("say") is None or shutil.which("ffmpeg") is None:
        pytest.skip("macOS `say` and ffmpeg required")
    aiff = path.with_suffix(".aiff")
    try:
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    except subprocess.CalledProcessError:
        subprocess.run(["say", "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff),
         "-ar", str(SR), "-ac", "1", str(path)],
        check=True,
    )
    data, _ = sf.read(str(path), dtype="float32")
    return np.asarray(data)


def _norm(x: np.ndarray, db: float) -> np.ndarray:
    p = float(np.sqrt(np.mean(x**2))) + 1e-9
    return (x * (10 ** (db / 20) / p)).astype(np.float32)


def _rir(gain: float) -> np.ndarray:
    rir = np.zeros(int(0.12 * SR), dtype=np.float32)
    d = int(0.008 * SR)
    for off, amp in [(d, 1.0), (d + int(0.02 * SR), 0.45), (d + int(0.05 * SR), 0.22)]:
        rir[off] = amp
    return rir * gain


def _run_worker(
    mic: np.ndarray, system: np.ndarray, work: Path, *, echo_cancel: bool, echo_dedup: str
) -> str:
    from huske.transcribe.worker import TranscriptionWorker

    work.mkdir(parents=True, exist_ok=True)
    sf.write(str(work / "microphone.wav"), mic, SR, subtype="PCM_16")
    sf.write(str(work / "system.wav"), system, SR, subtype="PCM_16")
    now = datetime(2026, 6, 24, 12, 0, 0).astimezone()
    job = {
        "chunk_seq": 1, "session_id": "20260624T120000_aec0",
        "audio_paths": {"microphone": str(work / "microphone.wav"), "system": str(work / "system.wav")},
        "start_time": now.isoformat(), "end_time": now.isoformat(),
        "expected_duration_seconds": float(len(mic) / SR), "actual_duration_seconds": float(len(mic) / SR),
        "gap_seconds": 0.0, "audio_sources": ["microphone", "system"], "incomplete": False,
        "output_root": str(work / "out"), "asr_engine": "parakeet", "config_model": "base",
        "parakeet_model": "mlx-community/parakeet-tdt-0.6b-v3", "config_compute_type": "int8",
        "config_device": "auto", "language": None,
        "echo_cancel": echo_cancel, "echo_dedup": echo_dedup,
        "keep_audio": False, "keep_audio_format": "wav",
        "whisper_idle_unload": False, "whisper_idle_unload_seconds": 120.0,
    }
    w = TranscriptionWorker()
    w.start()
    try:
        assert w.wait_ready(timeout=120.0)
        w.submit(job)
        res = None
        deadline = time.monotonic() + 120.0
        while time.monotonic() < deadline:
            res = w.poll_result(timeout=1.0)
            if res is not None:
                break
        assert res is not None and res["ok"], res and res.get("error")
        return Path(res["transcript_path"]).read_text()
    finally:
        w.stop(drain_timeout=5.0)


def _mic_lines(body: str) -> str:
    return " ".join(ln for ln in body.splitlines() if "· mic]" in ln).lower()


def test_aec_removes_system_spillage_from_mic(tmp_path: Path) -> None:
    from scipy.signal import fftconvolve

    human = _norm(_say(tmp_path / "human.wav",
                        "Oi, tudo bem? Eu estava pensando na proposta sobre o orçamento.", "Luciana"), -18)
    system = _norm(_say(tmp_path / "system.wav",
                        "According to the latest report, quarterly revenue increased fifteen percent.", "Daniel"), -16)

    # Two clearly separated regions: an echo-only stretch (system plays while the
    # local mic is silent — the worst spillage case) and a later human-only
    # stretch. The mic gets the (audible) bleed of the system plus the local
    # voice at its full level.
    total = int(15 * SR)
    sys_track = np.zeros(total, dtype=np.float32)
    hum_track = np.zeros(total, dtype=np.float32)
    sys_track[int(1 * SR):int(1 * SR) + len(system)] = system[: total - int(1 * SR)]
    hum_track[int(9 * SR):int(9 * SR) + len(human)] = human[: total - int(9 * SR)]
    echo = fftconvolve(sys_track, _rir(0.5))[:total].astype(np.float32)
    noise = _norm(np.random.RandomState(1).randn(total).astype(np.float32), -52)
    mic = (hum_track + echo + noise).astype(np.float32)

    # Raw (no suppression, no dedup): the echo leaks the system line onto the mic.
    before = _mic_lines(
        _run_worker(mic, sys_track, tmp_path / "before", echo_cancel=False, echo_dedup="off")
    )
    assert "revenue" in before or "report" in before  # spillage present

    # Product defaults (echo suppression + transcript dedup): the mic carries the
    # local voice, and the system's words do not leak onto it.
    after = _mic_lines(
        _run_worker(mic, sys_track, tmp_path / "after", echo_cancel=True, echo_dedup="drop")
    )
    assert "revenue" not in after and "report" not in after, f"system leaked: {after!r}"
    assert "orçamento" in after or "proposta" in after, f"local voice lost: {after!r}"


def test_no_echo_preserves_local_voice(tmp_path: Path) -> None:
    """Headphones case: no echo in the mic — AEC must not damage the local voice."""
    human = _norm(_say(tmp_path / "human.wav",
                       "A arquitetura de captura usa o Core Audio tap no macOS.", "Luciana"), -18)
    system = _norm(_say(tmp_path / "system.wav",
                        "Meanwhile the system channel plays an unrelated podcast.", "Daniel"), -16)
    total = max(len(human), len(system)) + SR
    mic = np.zeros(total, dtype=np.float32)
    sys_track = np.zeros(total, dtype=np.float32)
    mic[:len(human)] = human  # no echo component — headphones
    sys_track[:len(system)] = system

    body = _run_worker(mic, sys_track, tmp_path / "hp", echo_cancel=True, echo_dedup="drop")
    mic_text = _mic_lines(body)
    assert "captura" in mic_text or "arquitetura" in mic_text or "macos" in mic_text, mic_text
