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

import numpy as np
import numpy.typing as npt
from scipy import signal as _sig

NDArrayF32 = npt.NDArray[np.float32]

_EPS = 1e-9


def _to_mono_f32(x: np.ndarray) -> NDArrayF32:
    if x.ndim > 1:
        x = x.mean(axis=1)
    return np.ascontiguousarray(x, dtype=np.float32)


def estimate_delay(near: np.ndarray, far: np.ndarray, sr: int, max_ms: float = 200.0) -> int:
    """Return the lag (in samples) of ``far``'s echo within ``near``.

    Positive lag means the echo in the mic arrives *after* the reference (the
    usual acoustic + buffering latency). Found from the cross-correlation peak
    over an energetic window, limited to a plausible echo delay.
    """
    n = min(len(near), len(far))
    if n < sr // 10:
        return 0
    win = min(n, sr * 8)
    a = near[:win].astype(np.float64)
    b = far[:win].astype(np.float64)
    a = a - a.mean()
    b = b - b.mean()
    max_lag = int(max_ms * sr / 1000.0)
    corr = _sig.correlate(a, b, mode="full", method="fft")
    lags = np.arange(-(win - 1), win)
    keep = (lags >= 0) & (lags <= max_lag)
    if not keep.any():
        return 0
    sub = corr[keep]
    return max(0, int(lags[keep][int(np.argmax(np.abs(sub)))]))


def cancel_echo(
    near: np.ndarray,
    far: np.ndarray,
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
    if delay > 0:
        far_aligned = np.concatenate([np.zeros(delay, dtype=np.float32), far_t])[:n]
    else:
        far_aligned = far_t

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
    return out.astype(np.float32)


def erle_db(near: np.ndarray, cleaned: np.ndarray) -> float:
    """Echo Return Loss Enhancement (dB) — energy removed; higher is better.

    Meaningful on echo-only segments (no near-end speech).
    """
    near = _to_mono_f32(near)
    cleaned = _to_mono_f32(cleaned)
    n = min(len(near), len(cleaned))
    pn = float(np.dot(near[:n], near[:n])) + _EPS
    pc = float(np.dot(cleaned[:n], cleaned[:n])) + _EPS
    return float(10.0 * np.log10(pn / pc))
