"""`huske echo-test`: prove echo cancellation on this Mac's real hardware.

Plays a short spoken phrase through the current output device while capturing
mic + system audio exactly as `huske run` does (synced aggregate first,
independent streams as fallback). It then runs the same canceller the
transcription worker uses and reports how much of the speaker bleed it removed.
Nothing is written to disk except a temporary TTS clip, which is deleted.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

NDArrayF32 = npt.NDArray[np.float32]

_PHRASE = (
    "This is the huske echo test. If you can read these words in the "
    "microphone transcript, the speakers are leaking into the microphone."
)
_SR = 16000


@dataclass
class EchoTestResult:
    output_device: str | None
    mic_device: str | None
    capture_mode: str  # "synced" | "separate"
    method: str  # canceller used
    echo_present: bool
    echo_delay_ms: float | None
    coherence: float
    mic_level_db: float  # mic during playback, before cancellation
    residual_level_db: float  # after cancellation
    erle_db: float  # echo removed (dB)
    verdict: str

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


def _db(x: NDArrayF32) -> float:
    if x.size == 0:
        return -120.0
    return float(10.0 * np.log10(np.mean(np.square(x, dtype=np.float64)) + 1e-12))


def _tts_clip(path: Path) -> float:
    """Render the phrase with macOS `say`; returns its duration in seconds."""
    subprocess.run(
        ["/usr/bin/say", "-o", str(path), _PHRASE],
        check=True,
        capture_output=True,
        timeout=30,
    )
    import soundfile as sf

    info = sf.info(str(path))
    return float(info.frames) / float(info.samplerate)


def _to_16k(x: NDArrayF32, sr: int) -> NDArrayF32:
    if sr == _SR or x.size == 0:
        return np.ascontiguousarray(x, dtype=np.float32)
    import soxr

    return np.asarray(soxr.resample(x, sr, _SR), dtype=np.float32)


def _capture(seconds: float, play: Path, mic_name: str | None) -> tuple[NDArrayF32, NDArrayF32, str, str | None]:
    """Record mic + system while `afplay` plays ``play``. Returns 16 kHz arrays."""
    from huske.capture.coordinator import open_synced_capture

    events: list[str] = []
    try:
        stream = open_synced_capture(mic_name, lambda _s, m: events.append(m))
    except Exception:
        return _capture_separate(seconds, play, mic_name)

    mic_parts: list[NDArrayF32] = []
    sys_parts: list[NDArrayF32] = []
    try:
        time.sleep(0.5)  # let the aggregate settle before playback
        stream.drain_available()
        player = subprocess.Popen(["/usr/bin/afplay", str(play)])
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            time.sleep(0.05)
            for mic, sys_, _when in stream.drain_available():
                mic_parts.append(mic)
                sys_parts.append(sys_)
        player.wait(timeout=10)
        for mic, sys_, _when in stream.drain_available():
            mic_parts.append(mic)
            sys_parts.append(sys_)
        rate = stream.sample_rate
        mic_name_used = stream.mic.name
    finally:
        stream.stop()
    if not mic_parts:
        raise RuntimeError(
            "the synced capture delivered no audio — check Microphone and "
            "System Audio Recording permissions for the app running huske"
        )
    mic = _to_16k(np.concatenate(mic_parts), rate)
    sys_ = _to_16k(np.concatenate(sys_parts), rate)
    return mic, sys_, "synced", mic_name_used


def _capture_separate(
    seconds: float, play: Path, mic_name: str | None
) -> tuple[NDArrayF32, NDArrayF32, str, str | None]:
    import sounddevice as sd

    from huske.capture.system_audio_tap import CoreAudioTapStream

    rate = 48000
    tap = CoreAudioTapStream(sample_rate=rate)
    tap.start()
    try:
        time.sleep(0.3)
        tap.drain_available()
        player = subprocess.Popen(["/usr/bin/afplay", str(play)])
        rec = sd.rec(int(seconds * rate), samplerate=rate, channels=1, dtype="float32", device=mic_name)
        sd.wait()
        player.wait(timeout=10)
        sys_parts = [b for b, _ in tap.drain_available()]
    finally:
        tap.stop()
    mic = _to_16k(np.asarray(rec[:, 0], dtype=np.float32), rate)
    sys_ = _to_16k(np.concatenate(sys_parts) if sys_parts else np.zeros(0, np.float32), rate)
    n = min(len(mic), len(sys_))
    return mic[:n], sys_[:n], "separate", mic_name


def run_echo_test(mic_name: str | None = None, method: str = "auto") -> EchoTestResult:
    from huske.capture import coreaudio_hal as hal
    from huske.transcribe.aec import (
        _ECHO_PRESENT_MIN_MSC,
        echo_coherence,
        estimate_delay,
        remove_echo,
    )

    out_dev = hal.default_output_device()
    output_name = hal.device_name(out_dev) if out_dev else None

    fd, tmp = tempfile.mkstemp(prefix="huske-echo-test-", suffix=".aiff")
    os.close(fd)
    clip = Path(tmp)
    try:
        duration = _tts_clip(clip)
        mic, sys_, mode, mic_used = _capture(duration + 1.5, clip, mic_name)
    finally:
        clip.unlink(missing_ok=True)

    n = min(len(mic), len(sys_))
    mic, sys_ = mic[:n], sys_[:n]
    active = np.abs(sys_) > 1e-3
    if not active.any():
        raise RuntimeError(
            "system audio stayed silent — is the output muted, or is the tap "
            "missing System Audio Recording permission?"
        )
    first, last = int(np.argmax(active)), int(n - np.argmax(active[::-1]))
    window = slice(first, last)

    lag = estimate_delay(mic, sys_, _SR)
    coherence = echo_coherence(mic, sys_, _SR, lag)
    present = coherence >= _ECHO_PRESENT_MIN_MSC
    cleaned, used = remove_echo(mic, sys_, _SR, method=method)
    before = _db(mic[window])
    after = _db(cleaned[window])
    erle = before - after

    if not present:
        verdict = (
            "No echo path detected — the mic does not hear the output "
            f"({output_name or 'unknown device'}). Headphones, or the volume is "
            "too low to leak. Nothing to cancel."
        )
    elif erle >= 15.0:
        verdict = f"Echo cancelled: {erle:.0f} dB of speaker bleed removed from the mic."
    elif erle >= 6.0:
        verdict = (
            f"Echo reduced by {erle:.0f} dB. Some residual may remain; the "
            "transcript de-dup removes what still transcribes."
        )
    else:
        verdict = (
            f"Echo barely reduced ({erle:.1f} dB). Run again in a quiet room; if "
            "it persists, report it with `huske doctor` output."
        )
    return EchoTestResult(
        output_device=output_name,
        mic_device=mic_used,
        capture_mode=mode,
        method=used,
        echo_present=present,
        echo_delay_ms=round(lag * 1000.0 / _SR, 1) if present else None,
        coherence=round(coherence, 4),
        mic_level_db=round(before, 1),
        residual_level_db=round(after, 1),
        erle_db=round(erle, 1),
        verdict=verdict,
    )
