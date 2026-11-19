"""Acoustic echo cancellation for the mic ← system speaker bleed.

When huske records mic + system audio on speakers (no headphones), the system
output is played acoustically and re-captured by the microphone — a delayed,
attenuated, room-filtered copy of the (clean) system channel. Transcribed as
is, every remote line appears twice.

Primary canceller: **WebRTC AEC3** (:func:`cancel_echo_webrtc`) — the echo
canceller in Chrome/Meet and in most mic+system meeting recorders, reached
through LiveKit's audio-processing binding. It adapts a linear echo-path filter
plus a residual suppressor and removes the bleed nearly completely while
keeping the local voice, including during double talk (ADR 0012). AEC3 needs
the far-end reference to *lead* the echo by a bounded, slowly-varying amount,
so before running it we measure the bulk mic↔system offset and shift the two
streams so the reference leads by a fixed margin (Chromium uses the same
170 ms trick for its system-audio reference). Since 0.15 the capture layer
records both channels from one Core Audio aggregate device on one clock, which
makes that offset constant; the per-window re-alignment here keeps older or
fallback captures (independent clocks) working too.

Fallback: **coherence-based echo suppression** (:func:`cancel_echo`), pure
numpy/scipy, used when the WebRTC binding is unavailable. It only reduces the
bleed (~10 dB). Either way, the transcript-level :mod:`huske.transcribe.dedup`
pass remains the backstop for any residual that still transcribes.
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


# STFT of a long monologue at these hop settings is multi-GB. Process at most
# this much audio at a time and overlap-add. Short files stay on the original
# single-STFT path so existing tests (and headphones/self-gate) are unchanged.
_ECHO_WINDOW_SECONDS = 8.0
_ECHO_OVERLAP_SECONDS = 2.0


def echo_window_bounds(
    n: int,
    sr: int,
    *,
    window_seconds: float = _ECHO_WINDOW_SECONDS,
    overlap_seconds: float = _ECHO_OVERLAP_SECONDS,
) -> list[tuple[int, int]]:
    """Inclusive-exclusive ``[start, end)`` sample ranges covering ``n`` samples."""
    if n <= 0:
        return []
    win = max(1, int(window_seconds * sr))
    overlap = max(0, min(win - 1, int(overlap_seconds * sr)))
    hop = max(1, win - overlap)
    if n <= win:
        return [(0, n)]
    bounds: list[tuple[int, int]] = []
    start = 0
    while start < n:
        end = min(start + win, n)
        bounds.append((start, end))
        if end >= n:
            break
        start += hop
    return bounds


def _suppress_stft(
    near: NDArrayF32,
    far: NDArrayF32,
    sr: int,
    *,
    beta: float,
    smoothing: float,
    gain_floor_db: float,
    nperseg: int,
    noverlap: int,
) -> NDArrayF32:
    """Coherence suppressor for one already-aligned window."""
    n = min(len(near), len(far))
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    near_t = near[:n]
    far_t = far[:n]
    _, _, X = _sig.stft(near_t, fs=sr, nperseg=nperseg, noverlap=noverlap)
    _, _, Y = _sig.stft(far_t, fs=sr, nperseg=nperseg, noverlap=noverlap)
    a = smoothing
    b_coef = [1.0 - a]
    a_coef = [1.0, -a]
    sxx = _sig.lfilter(b_coef, a_coef, np.abs(X) ** 2, axis=1)
    syy = _sig.lfilter(b_coef, a_coef, np.abs(Y) ** 2, axis=1)
    sxy = _sig.lfilter(b_coef, a_coef, X * np.conj(Y), axis=1)
    coh = (np.abs(sxy) ** 2) / (sxx * syy + _EPS)
    floor = 10 ** (gain_floor_db / 20.0)
    gain = np.maximum(floor, (1.0 - np.clip(coh, 0.0, 1.0)) ** beta)
    _, out = _sig.istft(X * gain, fs=sr, nperseg=nperseg, noverlap=noverlap)
    out = np.asarray(out[:n], dtype=np.float32)
    if len(out) < n:
        out = np.concatenate([out, np.zeros(n - len(out), dtype=np.float32)])
    return cast(NDArrayF32, out)


def _ola_taper(length: int, start: int, end: int, n: int, overlap: int) -> NDArrayF32:
    """Fade in/out on the overlapped edges so adjacent windows crossfade."""
    w = np.ones(length, dtype=np.float32)
    ov = min(overlap, length)
    if ov <= 0:
        return cast(NDArrayF32, w)
    ramp = np.linspace(0.0, 1.0, ov, dtype=np.float32)
    if start > 0:
        w[:ov] *= ramp
    if end < n:
        w[-ov:] *= ramp[::-1]
    return cast(NDArrayF32, w)


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
    window_seconds: float = _ECHO_WINDOW_SECONDS,
    overlap_seconds: float = _ECHO_OVERLAP_SECONDS,
) -> NDArrayF32:
    """Suppress the acoustic echo of ``far`` (system) in ``near`` (mic).

    Both are mono float32 at ``sr``. Returns a near signal of the same length
    with the system-coherent (echo) content attenuated. ``beta`` controls
    aggressiveness (gain ``(1 - coherence) ** beta``); ``smoothing`` is the
    recursive-averaging factor for the local spectra. Safe when there is no
    echo (coherence ≈ 0 → gain ≈ 1).

    Long files are processed in ``window_seconds`` hops so the STFT working
    set stays bounded (~tens of MB) instead of scaling with the whole chunk.
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

    bounds = echo_window_bounds(
        n, sr, window_seconds=window_seconds, overlap_seconds=overlap_seconds
    )
    if len(bounds) <= 1:
        cleaned = _suppress_stft(
            near_t,
            far_aligned,
            sr,
            beta=beta,
            smoothing=smoothing,
            gain_floor_db=gain_floor_db,
            nperseg=nperseg,
            noverlap=noverlap,
        )
    else:
        overlap = max(0, int(overlap_seconds * sr))
        acc = np.zeros(n, dtype=np.float64)
        weight = np.zeros(n, dtype=np.float64)
        for start, end in bounds:
            piece = _suppress_stft(
                near_t[start:end],
                far_aligned[start:end],
                sr,
                beta=beta,
                smoothing=smoothing,
                gain_floor_db=gain_floor_db,
                nperseg=nperseg,
                noverlap=noverlap,
            )
            taper = _ola_taper(end - start, start, end, n, overlap)
            acc[start:end] += piece * taper
            weight[start:end] += taper
        weight = np.maximum(weight, _EPS)
        cleaned = (acc / weight).astype(np.float32)

    if tail.size:
        cleaned = np.concatenate([cleaned, tail])
    return cast(NDArrayF32, np.asarray(cleaned, dtype=np.float32))


# --- WebRTC AEC3 -------------------------------------------------------------

#: AEC3 works on 10 ms frames. Any other frame length trips an assertion inside
#: the native library that aborts the *process*, so every call goes through
#: :func:`_aec3_frames`, which only ever emits exact 10 ms frames.
_AEC3_RATES = (16000, 32000, 48000)
#: Fixed algorithmic latency of the AEC3 capture path at 16 kHz (measured:
#: the cleaned output is the input delayed by exactly 128 samples = 8 ms).
_AEC3_LATENCY_SAMPLES_16K = 128
#: How far the reference should lead the echo. AEC3's delay search covers
#: roughly 0-400 ms of reference lead; centring the true echo at 170 ms leaves
#: ±~170 ms of slack for estimation error and drift (Chromium uses the same).
_AEC3_TARGET_LEAD_MS = 170.0
#: Re-alignment window for long chunks: one APM per window, warmed up on the
#: preceding audio so it is converged when the window's own output starts.
_AEC3_WINDOW_SECONDS = 120.0
_AEC3_WARMUP_SECONDS = 4.0
#: If the per-window offsets agree within this spread, the whole chunk is
#: processed in one continuous pass (AEC3 tracks small changes on its own).
_AEC3_STABLE_SPREAD_MS = 80.0


def webrtc_aec_available() -> bool:
    """True iff the WebRTC AEC3 binding (``livekit.rtc``) can be imported."""
    try:
        from livekit import rtc  # noqa: F401
    except Exception:
        return False
    return True


def _aec3_process(
    near: NDArrayF32,
    far: NDArrayF32,
    sr: int,
) -> NDArrayF32:
    """Run AEC3 once over two equal-length, pre-shifted streams.

    Returns the cleaned near signal, re-aligned to ``near`` (the algorithmic
    latency is compensated), same length.
    """
    from livekit import rtc

    frame = sr // 100
    latency = round(_AEC3_LATENCY_SAMPLES_16K * sr / 16000)
    n = len(near)
    # Pad so the tail flushes through the latency and fills a whole frame.
    total = n + latency
    total += (-total) % frame
    near_i16 = np.zeros(total, dtype=np.int16)
    far_i16 = np.zeros(total, dtype=np.int16)
    near_i16[:n] = np.clip(near * 32767.0, -32768, 32767).astype(np.int16)
    far_i16[: len(far)] = np.clip(far[:total] * 32767.0, -32768, 32767).astype(np.int16)

    apm = rtc.AudioProcessingModule(
        echo_cancellation=True,
        noise_suppression=False,
        high_pass_filter=True,
        auto_gain_control=False,
    )
    out = np.empty(total, dtype=np.int16)
    for i in range(0, total, frame):
        ref = rtc.AudioFrame.create(sr, 1, frame)
        np.frombuffer(ref.data, dtype=np.int16)[:] = far_i16[i : i + frame]
        apm.process_reverse_stream(ref)
        # Required whenever echo cancellation is on. The streams are already
        # shifted so the reference leads; AEC3 estimates the rest itself.
        apm.set_stream_delay_ms(0)
        cap = rtc.AudioFrame.create(sr, 1, frame)
        np.frombuffer(cap.data, dtype=np.int16)[:] = near_i16[i : i + frame]
        apm.process_stream(cap)
        out[i : i + frame] = np.frombuffer(cap.data, dtype=np.int16)
    cleaned = out[latency : latency + n].astype(np.float32) / 32767.0
    return cast(NDArrayF32, cleaned)


def _shift_for_lead(
    near: NDArrayF32,
    far: NDArrayF32,
    lag: int,
    lead: int,
) -> tuple[NDArrayF32, NDArrayF32, int]:
    """Shift streams so the echo sits ``lead`` samples after the reference.

    ``lag`` is :func:`estimate_delay`'s answer (echo position relative to the
    reference). Returns ``(near', far', mic_shift)`` where ``mic_shift`` is how
    many samples the mic was delayed — the caller drops that many samples from
    the front of the cleaned output to re-align it with the original mic.
    """
    if lag < lead:
        # Reference leads too little (or is late): delay the mic.
        mic_shift = lead - lag
        near_s = np.concatenate([np.zeros(mic_shift, dtype=np.float32), near])
        far_s = np.concatenate([far, np.zeros(mic_shift, dtype=np.float32)])
        return cast(NDArrayF32, near_s), cast(NDArrayF32, far_s), mic_shift
    # Reference leads by more than needed: delay the reference instead.
    ref_shift = lag - lead
    far_s = np.concatenate([np.zeros(ref_shift, dtype=np.float32), far])[: len(far)]
    return near, cast(NDArrayF32, far_s), 0


def _aec3_aligned(
    near: NDArrayF32,
    far: NDArrayF32,
    sr: int,
    lag: int,
    lead: int,
) -> NDArrayF32:
    near_s, far_s, mic_shift = _shift_for_lead(near, far, lag, lead)
    cleaned = _aec3_process(near_s, far_s, sr)
    return cleaned[mic_shift : mic_shift + len(near)]


#: Echo-presence gate. Mean magnitude-squared coherence (200 Hz-4 kHz) between
#: the mic and the lag-aligned reference, over frames where the reference is
#: active. Speakers measure 0.1-0.4 (0.01 even for a faint echo 30 dB under
#: the reference); headphones measure ≈0.001 — the estimator's bias floor,
#: about 1/segments. Without an echo path AEC3 never converges and keeps a
#: conservative suppressor on, which can dent the local voice, so it only runs
#: when there is an echo to cancel.
_ECHO_PRESENT_MIN_MSC = 0.004
_MSC_NPERSEG = 512


def echo_coherence(near: NDArrayAny, far: NDArrayAny, sr: int, lag: int) -> float:
    """Mean coherence of ``near`` with ``far`` shifted by ``lag`` (≈0 = no echo)."""
    near = _to_mono_f32(near)
    far = _to_mono_f32(far)
    n = min(len(near), len(far))
    if n < _MSC_NPERSEG * 4:
        return 0.0
    aligned = _align_far_to_near(far[:n], lag, n)
    hop = _MSC_NPERSEG // 2
    frames = n // hop
    if frames < 8:
        return 0.0
    # Keep only frames where the reference carries sound (> -50 dBFS).
    energy = np.square(aligned[: frames * hop], dtype=np.float64).reshape(frames, hop).mean(axis=1)
    active = energy > 10 ** (-50.0 / 10.0)
    if int(active.sum()) < 8:
        return 0.0
    keep = np.repeat(active, hop)
    m = near[: frames * hop][keep]
    f = aligned[: frames * hop][keep]
    freqs, coh = _sig.coherence(m, f, fs=sr, nperseg=_MSC_NPERSEG)
    band = (freqs >= 200.0) & (freqs <= 4000.0)
    segments = max(1, (len(m) - _MSC_NPERSEG) // hop + 1)
    # Bias floor of the estimator is ~1/segments; require clear headroom over it.
    value = float(np.mean(coh[band]))
    return value if value >= 3.0 / segments else 0.0


def _window_lags(
    near: NDArrayF32,
    far: NDArrayF32,
    sr: int,
    bounds: list[tuple[int, int]],
) -> list[int | None]:
    """Per-window echo lag, or None where the reference is silent."""
    silent = 10 ** (-60.0 / 20.0)
    lags: list[int | None] = []
    for start, end in bounds:
        if _rms(far[start:end]) < silent:
            lags.append(None)
            continue
        lags.append(estimate_delay(near[start:end], far[start:end], sr))
    return lags


def cancel_echo_webrtc(
    near: NDArrayAny,
    far: NDArrayAny,
    sr: int = 16000,
    *,
    target_lead_ms: float = _AEC3_TARGET_LEAD_MS,
    window_seconds: float = _AEC3_WINDOW_SECONDS,
    warmup_seconds: float = _AEC3_WARMUP_SECONDS,
) -> NDArrayF32:
    """Remove ``far``'s acoustic echo from ``near`` with WebRTC AEC3.

    Both inputs are mono at ``sr`` (16/32/48 kHz). Returns a cleaned ``near``
    of the same length and time base. Raises ``ImportError`` if the binding is
    missing — use :func:`remove_echo` for automatic fallback.

    Self-gating like the coherence suppressor: with headphones there is no
    echo path, AEC3's filter stays near zero and the local voice passes.
    """
    if sr not in _AEC3_RATES:
        raise ValueError(f"AEC3 supports {_AEC3_RATES} Hz, got {sr}")
    from livekit import rtc  # noqa: F401  (fail fast with ImportError)

    near = _to_mono_f32(near)
    far = _to_mono_f32(far)
    if near.size == 0:
        return near
    if far.size == 0 or _rms(far) < 10 ** (-60.0 / 20.0):
        return near.copy()

    n = len(near)
    if len(far) < n:
        far = np.concatenate([far, np.zeros(n - len(far), dtype=np.float32)])
    far = far[:n]
    lead = round(target_lead_ms * sr / 1000.0)

    bounds = echo_window_bounds(n, sr, window_seconds=window_seconds, overlap_seconds=0.0)
    lags = _window_lags(near, far, sr, bounds)
    known = [lag for lag in lags if lag is not None]
    if not known:
        return near.copy()
    spread_ms = (max(known) - min(known)) * 1000.0 / sr
    if len(bounds) == 1 or spread_ms <= _AEC3_STABLE_SPREAD_MS:
        # One continuous pass: the offset is stable (the normal case with
        # single-clock capture), so AEC3 adapts once and keeps converging.
        lag = int(np.median(known))
        if echo_coherence(near, far, sr, lag) < _ECHO_PRESENT_MIN_MSC:
            return near.copy()  # headphones: nothing to cancel
        return _aec3_aligned(near, far, sr, lag, lead)

    # Offsets wander (independent capture clocks): re-align per window, each
    # with a fresh canceller warmed up on the audio just before the window.
    out = near.copy()
    warm = int(warmup_seconds * sr)
    for (start, end), wlag in zip(bounds, lags, strict=True):
        if wlag is None:
            continue
        if echo_coherence(near[start:end], far[start:end], sr, wlag) < _ECHO_PRESENT_MIN_MSC:
            continue
        ws = max(0, start - warm)
        cleaned = _aec3_aligned(near[ws:end], far[ws:end], sr, wlag, lead)
        out[start:end] = cleaned[start - ws :]
    return out


EchoMethod = str  # "auto" | "webrtc" | "coherence"


def remove_echo(
    near: NDArrayAny,
    far: NDArrayAny,
    sr: int = 16000,
    *,
    method: EchoMethod = "auto",
) -> tuple[NDArrayF32, str]:
    """Cancel ``far``'s echo in ``near`` with the best available method.

    Returns ``(cleaned, method_used)``. ``auto`` prefers WebRTC AEC3 and falls
    back to coherence suppression when the binding is missing or fails.
    """
    if method == "webrtc":
        return cancel_echo_webrtc(near, far, sr), "webrtc"
    if method == "auto":
        try:
            return cancel_echo_webrtc(near, far, sr), "webrtc"
        except Exception:
            # Binding missing (non-arm64 / stripped install) or a native
            # failure: never lose the chunk over echo handling.
            pass
    return cancel_echo(near, far, sr), "coherence"


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
    cleaned_mic: NDArrayAny | None = None,
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
    cleaned = _to_mono_f32(cleaned_mic) if cleaned_mic is not None else None
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
        if cleaned is not None:
            cleaned_win = _slice_seconds(cleaned, sr, window_start, window_end)[:n]
            erle = erle_db(mic_win, cleaned_win)
        else:
            erle = acoustic_echo_erle(mic_win, sys_win, sr)
        if erle >= min_erle_db:
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
