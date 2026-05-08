"""Capture coordinator: runs mic (sounddevice) + system audio (ScreenCaptureKit) in parallel
and forwards each source separately to the chunker so they can be transcribed independently.

Threads:
  - PortAudio audio thread (sounddevice-managed) calls ``_mic_callback`` directly
    for every input block. Mono conversion + peak-level update + push-to-ring-buffer
    happen here. No Python loop is involved — the audio thread is high-priority
    and not subject to GIL contention from our other Python threads.
  - The SCStream sample-handler thread (ScreenCaptureKit-managed) supplies system mono
    frames via ``SystemAudioStream``'s internal queue.
  - Our ``_mixer_loop`` thread drains both ring buffers at fixed cadence and forwards
    each one to the chunker (the BlockSink) with its source tag — no mixing on disk.
    Per-source peaks for the UI are tracked at push time on each source's audio thread.

If system audio capture fails (permission missing, framework unavailable) the
coordinator degrades to mic-only and surfaces a sticky warning.
"""

from __future__ import annotations

import threading
from collections import deque
from collections.abc import Callable
from datetime import datetime
from typing import Protocol

import numpy as np
import sounddevice as sd

from huske.capture.system_audio import (
    SystemAudioPermissionError,
    SystemAudioStream,
)
from huske.capture.system_audio_tap import (
    CoreAudioTapPermissionError,
    CoreAudioTapStream,
    is_supported as is_tap_supported,
)
from huske.config import RuntimeConfig


SystemAudioBackendInstance = SystemAudioStream | CoreAudioTapStream
SystemAudioPermissionLike = SystemAudioPermissionError | CoreAudioTapPermissionError


class BlockSink(Protocol):
    def write_block(
        self,
        block: np.ndarray,
        source: str = "microphone",
        now: datetime | None = None,
    ) -> None: ...


_MIXER_BLOCK_SECONDS = 0.05  # 50 ms — well below any chunk-rotation timing concern


class _SourceBuffer:
    """Thread-safe append-only mono float32 buffer with a max-frame cap.

    Backpressure: if the buffer would exceed its cap, we drop the oldest frames
    and emit a 'warn' once. This protects against a stalled consumer.
    """

    def __init__(self, max_frames: int) -> None:
        self._max = max_frames
        self._chunks: deque[np.ndarray] = deque()
        self._n = 0
        self._lock = threading.Lock()
        self._dropped_warn = False

    def push(self, block: np.ndarray) -> bool:
        """Append `block` (mono float32). Returns True iff frames had to be dropped."""
        dropped = False
        with self._lock:
            self._chunks.append(block)
            self._n += block.shape[0]
            while self._n > self._max and self._chunks:
                old = self._chunks.popleft()
                self._n -= old.shape[0]
                dropped = True
        return dropped

    def take(self, n: int) -> np.ndarray:
        """Pop up to n mono samples. Returns a mono float32 array of length min(n, available)."""
        with self._lock:
            if self._n == 0 or n <= 0:
                return np.zeros(0, dtype=np.float32)
            taken: list[np.ndarray] = []
            remaining = n
            while remaining > 0 and self._chunks:
                head = self._chunks[0]
                if head.shape[0] <= remaining:
                    taken.append(head)
                    remaining -= head.shape[0]
                    self._chunks.popleft()
                    self._n -= head.shape[0]
                else:
                    taken.append(head[:remaining])
                    self._chunks[0] = head[remaining:]
                    self._n -= remaining
                    remaining = 0
            return np.concatenate(taken) if taken else np.zeros(0, dtype=np.float32)

    @property
    def available(self) -> int:
        with self._lock:
            return self._n


class CaptureCoordinator:
    """Drives mic (sounddevice) + system (SCStream) capture and feeds a chunker."""

    def __init__(
        self,
        cfg: RuntimeConfig,
        mic_device_index: int | None,
        sink: BlockSink,
        *,
        on_event: Callable[[str, str], None] | None = None,
        system_audio: bool = True,
        on_warning: Callable[[str, str], None] | None = None,
        on_warning_clear: Callable[[str], None] | None = None,
    ) -> None:
        self._cfg = cfg
        self._mic_device_index = mic_device_index
        self._sink = sink
        self._on_event = on_event or (lambda _s, _m: None)
        self._on_warning = on_warning or (lambda _k, _m: None)
        self._on_warning_clear = on_warning_clear or (lambda _k: None)
        self._system_audio_enabled = system_audio

        sr = cfg.sample_rate
        # ~3 seconds of headroom per source — generous; mixer should drain every 50 ms.
        max_frames = sr * 3
        self._mic_buf = _SourceBuffer(max_frames=max_frames)
        self._sys_buf = _SourceBuffer(max_frames=max_frames)

        self._mic_stream: sd.InputStream | None = None
        self._mixer_thread: threading.Thread | None = None
        self._system_stream: SystemAudioBackendInstance | None = None
        self._stop = threading.Event()

        self._mic_last: datetime | None = None
        self._sys_last: datetime | None = None
        self._mic_peak = 0.0
        self._sys_peak = 0.0
        self._peak_lock = threading.Lock()
        self._mic_active = False
        self._sys_active = False

    # ------------------------------------------------------------------ status

    @property
    def last_callback_at(self) -> datetime | None:
        candidates = [t for t in (self._mic_last, self._sys_last) if t is not None]
        return max(candidates) if candidates else None

    def peak_levels_db(self) -> tuple[float, float]:
        """Return (mic_db, system_db) peak since last call. dBFS, floor -120."""
        with self._peak_lock:
            mp, sp = self._mic_peak, self._sys_peak
            self._mic_peak = 0.0
            self._sys_peak = 0.0
        return (_to_db(mp), _to_db(sp))

    @property
    def mic_active(self) -> bool:
        return self._mic_active

    @property
    def system_active(self) -> bool:
        return self._sys_active

    # ----------------------------------------------------------------- startup

    def start(self) -> None:
        # Mic — uses sounddevice's callback API so PortAudio drives delivery
        # from its own real-time audio thread. This is robust against Python
        # GIL contention and macOS scheduler preemption that would otherwise
        # cause input buffer overflows under heavy CPU load (e.g., during
        # initial Whisper model loading in the worker subprocess).
        try:
            self._mic_stream = sd.InputStream(
                device=self._mic_device_index,
                channels=1,
                samplerate=self._cfg.sample_rate,
                blocksize=self._cfg.block_size,
                dtype="float32",
                latency="high",
                callback=self._mic_callback,
            )
            self._mic_stream.start()
            self._mic_active = True
            self._on_event("info", "microphone capture started")
        except Exception as exc:  # noqa: BLE001
            self._on_event("error", f"mic capture failed: {exc}")
            self._mic_active = False

        # System audio.
        if self._system_audio_enabled and self._cfg.system_audio_backend != "off":
            self._start_system_audio()

        if not self._mic_active and not self._sys_active:
            raise RuntimeError(
                "No audio source available — mic failed and system audio unavailable."
            )

        self._mixer_thread = threading.Thread(
            target=self._mixer_loop, name="huske-mixer", daemon=True
        )
        self._mixer_thread.start()

    def _start_system_audio(self) -> None:
        backend = self._cfg.system_audio_backend
        order: list[str]
        if backend == "tap":
            order = ["tap"]
        elif backend == "sck":
            order = ["sck"]
        else:  # auto
            order = ["tap", "sck"] if is_tap_supported() else ["sck"]

        last_error: Exception | None = None
        for choice in order:
            try:
                if choice == "tap":
                    self._system_stream = CoreAudioTapStream(
                        sample_rate=self._cfg.sample_rate,
                        on_event=self._on_event,
                    )
                else:
                    self._system_stream = SystemAudioStream(
                        sample_rate=self._cfg.sample_rate,
                        on_event=self._on_event,
                    )
                self._system_stream.start()
                self._sys_active = True
                self._on_warning_clear("system_audio")
                return
            except (SystemAudioPermissionError, CoreAudioTapPermissionError) as exc:
                last_error = exc
                self._on_event(
                    "warn",
                    f"system audio backend '{choice}' unavailable: {exc}",
                )
                self._system_stream = None
                continue
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                self._on_event(
                    "error", f"system audio backend '{choice}' failed: {exc}"
                )
                self._system_stream = None
                continue

        # Every backend in `order` failed.
        if isinstance(last_error, SystemAudioPermissionError):
            self._on_warning(
                "system_audio",
                "Screen Recording permission needed for system audio. "
                "System Settings → Privacy & Security → Screen Recording.",
            )
        elif isinstance(last_error, CoreAudioTapPermissionError):
            self._on_warning(
                "system_audio",
                "Core Audio tap unavailable — falling back to mic-only.",
            )
        else:
            self._on_warning(
                "system_audio",
                "System audio capture failed — mic-only mode.",
            )
        self._sys_active = False

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        if self._mic_stream is not None:
            try:
                self._mic_stream.stop()
                self._mic_stream.close()
            except Exception:  # noqa: BLE001
                pass
            self._mic_stream = None
        if self._system_stream is not None:
            try:
                self._system_stream.stop(timeout=timeout)
            except Exception:  # noqa: BLE001
                pass
            self._system_stream = None
        if self._mixer_thread is not None:
            self._mixer_thread.join(timeout=timeout)
            self._mixer_thread = None

    # ------------------------------------------------------------------ inner

    def _mic_callback(
        self,
        indata: np.ndarray,
        frames: int,
        time_info: object,
        status: object,
    ) -> None:
        """Called by sounddevice on the PortAudio audio thread for every block.

        Must not block, allocate large structures, or hold the GIL for long.
        Errors are swallowed (raising would crash the audio thread).
        """
        try:
            # `status` carries CallbackFlags. Only warn on real overflows;
            # `priming_output` and similar startup flags are not interesting.
            if getattr(status, "input_overflow", False):
                # Don't call back into self._on_event from the audio thread —
                # that may take locks held by slower threads. Just record it.
                self._on_event("warn", "mic buffer overflow")

            now = datetime.now().astimezone()
            self._mic_last = now

            if indata.ndim == 1:
                mono = indata
            elif indata.shape[1] == 1:
                mono = indata[:, 0]
            else:
                mono = indata.mean(axis=1).astype(np.float32, copy=False)

            if mono.size == 0:
                return

            peak = float(np.abs(mono).max())
            with self._peak_lock:
                if peak > self._mic_peak:
                    self._mic_peak = peak

            # Must copy: sounddevice reuses the buffer for the next callback.
            self._mic_buf.push(np.asarray(mono, dtype=np.float32).copy())
        except Exception:  # noqa: BLE001
            # Never propagate — would crash PortAudio's audio thread.
            return

    def _mixer_loop(self) -> None:
        sr = self._cfg.sample_rate
        block_frames = max(1, int(round(sr * _MIXER_BLOCK_SECONDS)))

        while not self._stop.is_set():
            # Pull system samples first (they arrive in larger irregular chunks).
            self._drain_system()

            # Mic is our reference clock — its callback fires at a steady rate
            # (set by PortAudio's blocksize). System audio arrives irregularly,
            # so we drain whatever's available alongside each mic tick.
            if not self._mic_active:
                # System-only fallback: drain at fixed cadence.
                avail = min(self._sys_buf.available, block_frames)
                if avail < block_frames // 4:
                    self._stop.wait(_MIXER_BLOCK_SECONDS)
                    continue
                sys_part = self._sys_buf.take(avail)
                if sys_part.size:
                    self._sink.write_block(sys_part, source="system")
                continue

            mic_avail = self._mic_buf.available
            if mic_avail < block_frames:
                # Wait briefly for more mic data; if stop or device dies, exit.
                self._stop.wait(_MIXER_BLOCK_SECONDS / 2)
                continue

            mic_part = self._mic_buf.take(block_frames)
            sys_part = self._sys_buf.take(block_frames)

            self._sink.write_block(mic_part, source="microphone")
            if sys_part.size:
                self._sink.write_block(sys_part, source="system")

        # Drain remaining buffered audio on shutdown.
        while self._mic_buf.available > 0 or self._sys_buf.available > 0:
            mic_part = self._mic_buf.take(self._mic_buf.available)
            sys_part = self._sys_buf.take(self._sys_buf.available)
            if mic_part.size:
                self._sink.write_block(mic_part, source="microphone")
            if sys_part.size:
                self._sink.write_block(sys_part, source="system")
            if mic_part.size == 0 and sys_part.size == 0:
                break

    def _drain_system(self) -> None:
        if self._system_stream is None:
            return
        for block, when in self._system_stream.drain_available():
            self._sys_last = when
            if block.size:
                peak = float(np.abs(block).max())
                with self._peak_lock:
                    if peak > self._sys_peak:
                        self._sys_peak = peak
            self._sys_buf.push(block)


def _to_db(x: float) -> float:
    if x <= 1e-6:
        return -120.0
    return float(20.0 * np.log10(min(x, 1.0)))
