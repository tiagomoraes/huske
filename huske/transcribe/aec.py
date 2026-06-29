"""Speaker-bleed reduction for the mic ← system spillage.

When huske records mic + system audio on speakers (no headphones), the system
output is played acoustically and re-captured by the microphone — a delayed,
attenuated, room-filtered copy of the (clean) system channel.

The ideal fix would be true acoustic echo cancellation (estimate the echo path
and subtract it). We investigated and simulated that: it works perfectly when
the mic and system are sample-aligned, but huske captures the mic (PortAudio)
and the system (Core Audio tap) on **independent clocks**, so their alignment
jitters by milliseconds and drifts over a chunk — there is no stable
linear-time-invariant echo path to subtract, and sample-precise cancellation
collapses (we measured negative ERLE on real recordings).

So we use **coherence-based echo suppression**, which is robust to that jitter
because it works on time-averaged spectra rather than sample-precise
subtraction. We suppress the time-frequency content of the mic that is
*coherent* with the system reference (the echo) and keep the incoherent content
(the local voice, room, noise). This is **self-gating**: with headphones there
is no echo, so mic and system are incoherent everywhere → the mic passes
through untouched. And it cannot remove the local voice, which is incoherent
with the system. It reduces the bleed (typically ~10-15 dB) rather than
eliminating it; the transcript-level :mod:`huske.transcribe.dedup` pass removes
whatever residual still transcribes.

Pure numpy + scipy (already dependencies).
"""

from __future__ import annotations

from typing import Any, cast

import numpy as np
import numpy.typing as npt
from scipy import signal as _sig

NDArrayF32 = npt.NDArray[np.float32]
NDArrayAny = npt.NDArray[Any]

_EPS = 1e-9


def _to_mono_f32(x: NDArrayAny) -> NDArrayF32:
    if x.ndim > 1:
        x = x.mean(axis=1)
    return np.ascontiguousarray(x, dtype=np.float32)


def _rms(x: NDArrayAny) -> float:
    if x.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64))))


def _rms_db(x: NDArrayAny) -> float:
    return 20.0 * float(np.log10(max(_rms(x), _EPS)))


def _best_joint_energy_window(
    near: NDArrayAny,
    far: NDArrayAny,
    sr: int,
    win: int,
) -> int:
    """Pick a correlation window that contains useful energy in both streams.

    Real chunks often start with only the local speaker, with the first system
    line arriving much later. Looking only at the first few seconds then
    estimates delay on silence/unrelated speech. This cheap scan finds a later
    energetic region before running the more expensive FFT correlation.
    """
    n = min(len(near), len(far))
    if n <= win:
        return 0
    hop = max(sr // 2, win // 4)
    starts = list(range(0, n - win + 1, hop))
    if starts[-1] != n - win:
        starts.append(n - win)

    starts_a = np.asarray(starts, dtype=np.int64)
    stops_a = starts_a + win
    near_sq = np.square(near[:n], dtype=np.float64)
    far_sq = np.square(far[:n], dtype=np.float64)
    near_cum = np.concatenate(([0.0], np.cumsum(near_sq)))
    far_cum = np.concatenate(([0.0], np.cumsum(far_sq)))
    near_energy = near_cum[stops_a] - near_cum[starts_a]
    far_energy = far_cum[stops_a] - far_cum[starts_a]
    scores = near_energy * far_energy
    if scores.size == 0:
        return 0
    best_idx = int(np.argmax(scores))
    best_score = float(scores[best_idx])
    if best_score <= 0.0:
        return 0
    return starts[best_idx]


def estimate_delay(
    near: NDArrayAny,
    far: NDArrayAny,
    sr: int,
    max_ms: float = 2000.0,
    window_seconds: float = 8.0,
) -> int:
    """Return the lag (in samples) of ``far``'s echo within ``near``.

    Positive lag means the echo in the mic arrives *after* the reference (the
    usual acoustic + buffering latency). Negative lag means the saved system
    reference is late relative to the mic echo, which can happen when the
    backend delivers queued system samples after the mic clock has advanced.
    Found from the cross-correlation peak over an energetic window, limited to a
    plausible capture-alignment delay.
    """
    near = _to_mono_f32(near)
    far = _to_mono_f32(far)
    n = min(len(near), len(far))
    if n < sr // 10:
        return 0
    win = min(n, max(sr // 10, int(window_seconds * sr)))
    start = _best_joint_energy_window(near[:n], far[:n], sr, win)
    a = near[start : start + win].astype(np.float64)
    b = far[start : start + win].astype(np.float64)
    if _rms(a) < 10 ** (-60.0 / 20.0) or _rms(b) < 10 ** (-60.0 / 20.0):
        return 0
    a = a - a.mean()
    b = b - b.mean()
    max_lag = min(int(max_ms * sr / 1000.0), win - 1)
    corr = _sig.correlate(a, b, mode="full", method="fft")
    lags = np.arange(-(win - 1), win)
    keep = (lags >= -max_lag) & (lags <= max_lag)
    if not keep.any():
        return 0
    sub = corr[keep]
    return int(lags[keep][int(np.argmax(np.abs(sub)))])


def _align_far_to_near(far: NDArrayF32, delay: int, n: int) -> NDArrayF32:
    """Shift ``far`` so its echo aligns with ``near``.

    ``delay`` follows :func:`estimate_delay`: positive pads the reference later;
    negative advances a late reference by dropping its leading samples.
    """
    if delay > 0:
        out = np.concatenate([np.zeros(delay, dtype=np.float32), far])[:n]
        return cast(NDArrayF32, out)
    if delay < 0:
        shift = min(-delay, len(far))
        out = far[shift : shift + n]
        if len(out) < n:
            out = np.concatenate([out, np.zeros(n - len(out), dtype=np.float32)])
        return cast(NDArrayF32, np.asarray(out, dtype=np.float32))
    return far[:n]


def cancel_echo(
    near: NDArrayAny,
    far: NDArrayAny,
    sr: int = 16000,
    *,
    beta: float = 2.0,
    smoothing: float = 0.8,
    gain_floor_db: float = -25.0,
    nperseg: int = 1024,
    noverlap: int = 768,
) -> NDArrayF32:
    """Suppress the acoustic echo of ``far`` (system) in ``near`` (mic).

    Both are mono float32 at ``sr``. Returns a near signal of the same length
    with the system-coherent (echo) content attenuated. ``beta`` controls
    aggressiveness (gain ``(1 - coherence) ** beta``); ``smoothing`` is the
    recursive-averaging factor for the local spectra. Safe when there is no
    echo (coherence ≈ 0 → gain ≈ 1).
    """
    near = _to_mono_f32(near)
    far = _to_mono_f32(far)
    if near.size == 0:
        return near
    if far.size == 0:
        return near.copy()
    # Nothing to cancel if the system reference is effectively silent.
    if float(np.sqrt(np.mean(far**2))) < 10 ** (-60.0 / 20.0):
        return near.copy()

    n = min(len(near), len(far))
    near_t = near[:n]
    far_t = far[:n]
    tail = near[n:]

    delay = estimate_delay(near_t, far_t, sr)
    far_aligned = _align_far_to_near(far_t, delay, n)

    _, _, X = _sig.stft(near_t, fs=sr, nperseg=nperseg, noverlap=noverlap)
    _, _, Y = _sig.stft(far_aligned, fs=sr, nperseg=nperseg, noverlap=noverlap)

    # Recursively-smoothed auto/cross spectra for a local coherence estimate.
    # The smoothing is a first-order IIR (s[t] = a·s[t-1] + (1-a)·p[t]) applied
    # along the time axis, vectorized with lfilter so cost is independent of how
    # long the chunk is (no per-frame Python loop).
    a = smoothing
    b_coef = [1.0 - a]
    a_coef = [1.0, -a]
    sxx = _sig.lfilter(b_coef, a_coef, np.abs(X) ** 2, axis=1)
    syy = _sig.lfilter(b_coef, a_coef, np.abs(Y) ** 2, axis=1)
    sxy = _sig.lfilter(b_coef, a_coef, X * np.conj(Y), axis=1)
    coh = (np.abs(sxy) ** 2) / (sxx * syy + _EPS)  # magnitude-squared coherence, 0..1
    floor = 10 ** (gain_floor_db / 20.0)
    gain = np.maximum(floor, (1.0 - np.clip(coh, 0.0, 1.0)) ** beta)

    _, out = _sig.istft(X * gain, fs=sr, nperseg=nperseg, noverlap=noverlap)
    out = np.asarray(out[:n], dtype=np.float32)
    if len(out) < n:
        out = np.concatenate([out, np.zeros(n - len(out), dtype=np.float32)])
    if tail.size:
        out = np.concatenate([out, tail])
    return cast(NDArrayF32, out.astype(np.float32))


def _temporally_near(mic: Any, sys: Any, max_lag_seconds: float) -> bool:
    mic_start = float(getattr(mic, "start", 0.0))
    mic_end = float(getattr(mic, "end", mic_start))
    sys_start = float(getattr(sys, "start", 0.0))
    sys_end = float(getattr(sys, "end", sys_start))
    if mic_start <= sys_end and sys_start <= mic_end:
        return True
    return (sys_start - max_lag_seconds) <= mic_start <= (sys_end + max_lag_seconds)


def _slice_seconds(
    audio: NDArrayF32,
    sr: int,
    start: float,
    end: float,
) -> NDArrayF32:
    i0 = max(0, min(len(audio), int(start * sr)))
    i1 = max(i0, min(len(audio), int(end * sr)))
    return audio[i0:i1]


def acoustic_echo_erle(
    mic_audio: NDArrayAny,
    system_audio: NDArrayAny,
    sr: int = 16000,
) -> float:
    """Return how echo-dominant a mic window is, in dB.

    High values mean the mic window can be strongly reduced using the system
    reference; low values mean it is mostly local voice or unrelated sound.
    """
    mic_audio = _to_mono_f32(mic_audio)
    system_audio = _to_mono_f32(system_audio)
    if mic_audio.size == 0 or system_audio.size == 0:
        return 0.0
    cleaned = cancel_echo(mic_audio, system_audio, sr)
    return erle_db(mic_audio, cleaned)


def mark_acoustic_echoes(
    segments: list[Any],
    mic_audio: NDArrayAny,
    system_audio: NDArrayAny,
    sr: int = 16000,
    *,
    min_erle_db: float = 5.5,
    max_lag_seconds: float = 2.0,
    pad_seconds: float = 2.0,
    min_segment_seconds: float = 0.25,
    min_system_db: float = -55.0,
) -> int:
    """Flag echo-dominant mic segments using audio coherence, not ASR text.

    Text de-dup handles the common case where the mic and system transcripts
    match. This is the backstop for noisy residual bleed where the mic ASR text
    is garbled enough not to match, but the underlying audio is still mostly a
    copy of the system channel. It only considers mic segments near an existing
    system segment so the cleaner system transcript remains available.
    """
    mic_audio = _to_mono_f32(mic_audio)
    system_audio = _to_mono_f32(system_audio)
    if mic_audio.size == 0 or system_audio.size == 0:
        return 0

    sys_segments = [s for s in segments if getattr(s, "source", "") == "system"]
    if not sys_segments:
        return 0

    marked = 0
    for seg in segments:
        if getattr(seg, "source", "") != "microphone" or getattr(seg, "echo", False):
            continue
        start = float(getattr(seg, "start", 0.0))
        end = float(getattr(seg, "end", start))
        if end - start < min_segment_seconds:
            continue
        if not any(_temporally_near(seg, sys, max_lag_seconds) for sys in sys_segments):
            continue

        window_start = max(0.0, start - pad_seconds)
        window_end = end + pad_seconds
        mic_win = _slice_seconds(mic_audio, sr, window_start, window_end)
        sys_win = _slice_seconds(system_audio, sr, window_start, window_end)
        n = min(len(mic_win), len(sys_win))
        if n == 0:
            continue
        mic_win = mic_win[:n]
        sys_win = sys_win[:n]
        if _rms_db(sys_win) < min_system_db:
            continue
        if acoustic_echo_erle(mic_win, sys_win, sr) >= min_erle_db:
            seg.echo = True
            marked += 1
    return marked


def erle_db(near: NDArrayAny, cleaned: NDArrayAny) -> float:
    """Echo Return Loss Enhancement (dB) — energy removed; higher is better.

    Meaningful on echo-only segments (no near-end speech).
    """
    near = _to_mono_f32(near)
    cleaned = _to_mono_f32(cleaned)
    n = min(len(near), len(cleaned))
    pn = float(np.dot(near[:n], near[:n])) + _EPS
    pc = float(np.dot(cleaned[:n], cleaned[:n])) + _EPS
    return float(10.0 * np.log10(pn / pc))
