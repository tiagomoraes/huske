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
from huske.transcribe.engines.base import Segment


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


def test_whisper_energy_gate_rejects_low_level_noise() -> None:
    from huske.transcribe.engines.whisper import _EnergyGate

    sr = 16_000
    audio = np.full(sr * 2, 0.0005, dtype=np.float32)
    gate = _EnergyGate(audio, sr)

    assert not gate.has_signal(0.5, 1.0)


def test_whisper_energy_gate_accepts_speech_above_noise_floor() -> None:
    from huske.transcribe.engines.whisper import _EnergyGate

    sr = 16_000
    audio = np.full(sr * 2, 0.0005, dtype=np.float32)
    start = int(0.8 * sr)
    end = int(1.2 * sr)
    t = np.arange(end - start, dtype=np.float32) / sr
    audio[start:end] += (0.02 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    gate = _EnergyGate(audio, sr)

    assert gate.has_signal(0.9, 1.1)
    assert not gate.has_signal(0.1, 0.2)


def test_whisper_energy_gate_keeps_continuous_speech_like_audio() -> None:
    from huske.transcribe.engines.whisper import _EnergyGate

    sr = 16_000
    t = np.arange(sr * 2, dtype=np.float32) / sr
    audio = (0.02 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    gate = _EnergyGate(audio, sr)

    assert gate.has_signal(0.5, 1.0)


def _fake_chunk(tmp_path: Path) -> Any:
    from datetime import datetime
    from types import SimpleNamespace

    now = datetime(2026, 6, 3, 12, 0, 0)
    return SimpleNamespace(
        chunk_seq=1,
        session_id="sess",
        audio_paths={"microphone": tmp_path / "m.wav"},
        audio_path=tmp_path / "m.wav",
        audio_sources=["microphone"],
        start_time=now,
        end_time=now,
        expected_duration_seconds=900.0,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        is_partial=False,
    )


def test_chunk_to_job_carries_idle_unload_config(tmp_path: Path) -> None:
    from huske.config import RuntimeConfig

    cfg = RuntimeConfig(whisper_idle_unload=True, whisper_idle_unload_seconds=45.0)
    job = worker.chunk_to_job(_fake_chunk(tmp_path), cfg)

    assert job["whisper_idle_unload"] is True
    assert job["whisper_idle_unload_seconds"] == 45.0


def test_chunk_to_job_idle_unload_defaults_on(tmp_path: Path) -> None:
    from huske.config import RuntimeConfig

    job = worker.chunk_to_job(_fake_chunk(tmp_path), RuntimeConfig())

    assert job["whisper_idle_unload"] is True
    assert job["whisper_idle_unload_seconds"] == 120.0


def test_chunk_to_job_carries_engine_selection(tmp_path: Path) -> None:
    from huske.config import RuntimeConfig

    cfg = RuntimeConfig(asr_engine="parakeet", echo_dedup="annotate")
    job = worker.chunk_to_job(_fake_chunk(tmp_path), cfg)

    assert job["asr_engine"] == "parakeet"
    assert job["parakeet_model"] == "mlx-community/parakeet-tdt-0.6b-v3"
    assert job["echo_dedup"] == "annotate"


def _speechlike(seconds: float, seed: int, sr: int = 16_000) -> np.ndarray:
    from scipy.signal import butter, lfilter

    rng = np.random.default_rng(seed)
    x = rng.standard_normal(int(seconds * sr)).astype(np.float32)
    b, a = butter(4, 3500 / (sr / 2))
    y = lfilter(b, a, x).astype(np.float32)
    return (y / (np.sqrt(np.mean(y**2)) + 1e-9) * 0.1).astype(np.float32)


def _room_echo(system: np.ndarray, *, gain: float = 0.8, sr: int = 16_000) -> np.ndarray:
    from scipy.signal import fftconvolve

    rir = np.zeros(int(0.12 * sr), dtype=np.float32)
    delay = int(0.008 * sr)
    rir[delay] = 1.0
    rir[delay + int(0.02 * sr)] = 0.4
    return fftconvolve(system, rir * gain)[: len(system)].astype(np.float32)


def test_mark_echoes_uses_acoustic_backstop_for_garbled_text() -> None:
    system = _speechlike(6.0, seed=21)
    mic = _room_echo(system)
    segs = [
        Segment(0.5, 4.5, "noisy unrelated words from microphone ASR", "microphone"),
        Segment(0.5, 4.5, "clean system transcript", "system"),
    ]

    worker._mark_echoes(segs, {"microphone": mic, "system": system}, "drop")

    assert segs[0].echo is True


def test_mark_echoes_off_skips_text_and_acoustic_marking() -> None:
    system = _speechlike(6.0, seed=22)
    mic = _room_echo(system)
    phrase = "the same phrase appears on both sources"
    segs = [
        Segment(0.5, 4.5, phrase, "microphone"),
        Segment(0.5, 4.5, phrase, "system"),
    ]

    worker._mark_echoes(segs, {"microphone": mic, "system": system}, "off")

    assert segs[0].echo is False


class _FakeQueue:
    """Minimal in_q stand-in recording the timeout each .get() was called with."""

    def __init__(self, result: Any = None, *, raise_empty: bool = False) -> None:
        self._result = result
        self._raise_empty = raise_empty
        self.timeouts: list[Any] = []

    def get(self, timeout: Any = None) -> Any:
        import queue as _queue

        self.timeouts.append(timeout)
        if self._raise_empty:
            raise _queue.Empty
        return self._result


def test_next_message_blocks_untimed_when_model_not_resident() -> None:
    q = _FakeQueue(result={"job": 1})
    msg = worker._next_message(q, model_resident=False, idle_unload=True, idle_unload_seconds=99.0)
    assert msg == {"job": 1}
    assert q.timeouts == [None]  # no timeout — nothing resident to reclaim


def test_next_message_untimed_when_idle_unload_disabled() -> None:
    q = _FakeQueue(result={"job": 2})
    msg = worker._next_message(q, model_resident=True, idle_unload=False, idle_unload_seconds=5.0)
    assert msg == {"job": 2}
    assert q.timeouts == [None]


def test_next_message_returns_job_arriving_within_idle_window() -> None:
    q = _FakeQueue(result={"job": 3})
    msg = worker._next_message(q, model_resident=True, idle_unload=True, idle_unload_seconds=5.0)
    assert msg == {"job": 3}
    assert q.timeouts == [5.0]  # waited with the idle timeout


def test_next_message_signals_unload_when_idle_window_elapses() -> None:
    q = _FakeQueue(raise_empty=True)
    msg = worker._next_message(q, model_resident=True, idle_unload=True, idle_unload_seconds=0.01)
    assert msg is worker._IDLE_TIMEOUT
    assert q.timeouts == [0.01]


# --- kept-audio compression (_compress_kept_audio) -------------------------


def _write_wav(path: Path, *, seconds: float = 1.0, sr: int = 48000) -> None:
    t = np.linspace(0, seconds, int(sr * seconds), endpoint=False)
    sig = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    sf.write(str(path), sig, sr, subtype="PCM_16")


def test_compress_kept_audio_opus_replaces_wav(tmp_path: Path) -> None:
    wav = tmp_path / "0001_091500_microphone.wav"
    _write_wav(wav)
    original = wav.stat().st_size

    worker._compress_kept_audio(wav, "opus")

    out = wav.with_suffix(".opus")
    assert out.exists() and not wav.exists()  # WAV replaced by the compressed copy
    assert out.stat().st_size < original  # smaller
    data, sr = sf.read(str(out))
    assert sr == 48000 and len(data) > 0  # still decodable


def test_compress_kept_audio_flac_replaces_wav(tmp_path: Path) -> None:
    wav = tmp_path / "0001_091500_system.wav"
    _write_wav(wav)
    worker._compress_kept_audio(wav, "flac")
    assert wav.with_suffix(".flac").exists() and not wav.exists()


def test_compress_kept_audio_unknown_format_is_noop(tmp_path: Path) -> None:
    wav = tmp_path / "x.wav"
    _write_wav(wav, seconds=0.1)
    worker._compress_kept_audio(wav, "mp3")  # unsupported → leave the WAV
    assert wav.exists()


def test_compress_kept_audio_keeps_original_on_failure(tmp_path: Path) -> None:
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"not a real wav")  # soundfile.read will raise
    worker._compress_kept_audio(bad, "opus")
    assert bad.exists()  # best-effort: never lose the recording
    assert not bad.with_suffix(".opus").exists()  # no partial output left behind
