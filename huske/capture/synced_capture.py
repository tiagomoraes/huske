"""Mic + system audio from ONE Core Audio aggregate device (one clock).

Why: echo cancellation subtracts the system channel's echo from the mic
channel, which needs the two to stay sample-aligned. Captured as independent
streams (PortAudio mic, separate tap aggregate), they run on different clocks
and arrive with different scheduling jitter, so their alignment wanders over a
session (ADR 0012). Here a private aggregate device contains:

* the microphone as its main sub-device (it supplies the clock), and
* a global process tap of system output, with drift compensation on, which
  Core Audio resamples onto the mic's clock.

One IOProc then delivers both in the same callback with identical frame
counts: by construction they never drift apart. The coordinator writes them to
the per-source WAVs unchanged, and the worker's AEC sees a constant echo delay.

Construction is verified at start-up (stream layout, equal frame counts); any
surprise raises :class:`SyncedCaptureError` and the coordinator falls back to
independent streams.
"""

from __future__ import annotations

import ctypes
import threading
import uuid
from collections import deque
from collections.abc import Callable
from datetime import datetime

import numpy as np
import numpy.typing as npt

from huske.capture import coreaudio_hal as hal
from huske.capture.system_audio_tap import (
    _AudioBuffer,
    _AudioDeviceIOProc,
    _AudioDeviceIOProcID,
    _fourcc,
    _load_coreaudio,
    is_supported,
)

NDArrayF32 = npt.NDArray[np.float32]


class SyncedCaptureError(RuntimeError):
    """The synchronized aggregate could not be built or did not behave."""


class SyncedCaptureStream:
    """Microphone + system tap delivered together, sample-aligned.

    ``drain_available()`` returns ``(mic_block, system_block, when)`` tuples
    whose two blocks always have the same length, at :attr:`sample_rate`.
    """

    def __init__(
        self,
        mic: hal.HalDevice,
        *,
        on_event: Callable[[str, str], None] | None = None,
        max_queued_blocks: int = 512,
    ) -> None:
        self._mic = mic
        self._on_event = on_event or (lambda _s, _m: None)
        self._tap_id: int | None = None
        self._agg_id: int | None = None
        self._proc_id: ctypes.c_void_p | None = None
        self._cb_obj: object | None = None
        self._ca: ctypes.CDLL | None = None
        self._mic_buffers = 0
        self._sample_rate: int | None = None
        self._queue: deque[tuple[NDArrayF32, NDArrayF32, datetime]] = deque(
            maxlen=max_queued_blocks
        )
        self._lock = threading.Lock()
        self._last_callback_at: datetime | None = None
        self._layout_errors = 0
        self._overflowed = False

    # ------------------------------------------------------------------ props

    @property
    def mic(self) -> hal.HalDevice:
        return self._mic

    @property
    def sample_rate(self) -> int:
        if self._sample_rate is None:
            raise SyncedCaptureError("stream not started")
        return self._sample_rate

    @property
    def last_callback_at(self) -> datetime | None:
        return self._last_callback_at

    @property
    def layout_errors(self) -> int:
        """Callbacks whose buffers did not match the expected mic + tap layout."""
        return self._layout_errors

    # --------------------------------------------------------------- callback

    def _io_callback(
        self,
        in_device: int,
        in_now: object,
        in_input: object,
        in_input_time: object,
        out_output: object,
        in_output_time: object,
        client_data: object,
    ) -> int:
        # Real-time thread: no raising, no logging, minimal allocation.
        try:
            if not in_input:
                return 0
            bl = in_input.contents  # type: ignore[attr-defined]
            n = int(bl.mNumberBuffers)
            if n != self._mic_buffers + 1:
                self._layout_errors += 1
                return 0
            bufs = ctypes.cast(
                ctypes.addressof(bl.mBuffers), ctypes.POINTER(_AudioBuffer * n)
            ).contents
            mic_buf = bufs[0]
            tap_buf = bufs[n - 1]
            mic = _first_channel(mic_buf)
            sys_ = _mono(tap_buf)
            if mic is None or sys_ is None or mic.shape[0] != sys_.shape[0]:
                self._layout_errors += 1
                return 0
            now = datetime.now().astimezone()
            with self._lock:
                if len(self._queue) == self._queue.maxlen:
                    self._queue.popleft()
                    self._overflowed = True
                self._queue.append((mic, sys_, now))
                self._last_callback_at = now
        except Exception:
            return 0
        return 0

    # -------------------------------------------------------------- lifecycle

    def start(self) -> None:
        if self._agg_id is not None:
            return
        if not is_supported():
            raise SyncedCaptureError("Core Audio process taps are not supported here")

        from CoreAudio import (
            AudioHardwareCreateAggregateDevice,
            AudioHardwareCreateProcessTap,
            CATapDescription,
            kAudioAggregateDeviceIsPrivateKey,
            kAudioAggregateDeviceMainSubDeviceKey,
            kAudioAggregateDeviceNameKey,
            kAudioAggregateDeviceSubDeviceListKey,
            kAudioAggregateDeviceTapListKey,
            kAudioAggregateDeviceUIDKey,
            kAudioSubDeviceUIDKey,
            kAudioSubTapDriftCompensationKey,
            kAudioSubTapUIDKey,
        )

        mic_layout = hal.stream_channels(self._mic.device_id)
        if not mic_layout:
            raise SyncedCaptureError(f"microphone '{self._mic.name}' has no input streams")
        self._mic_buffers = len(mic_layout)
        self._ca = _load_coreaudio()

        desc = CATapDescription.alloc().initMonoGlobalTapButExcludeProcesses_([])
        desc.setName_("huske-synced-system-audio")
        desc.setPrivate_(True)
        tap_uuid = str(desc.UUID())
        err, tap_id = AudioHardwareCreateProcessTap(desc, None)
        if err != 0 or not tap_id:
            raise SyncedCaptureError(
                f"AudioHardwareCreateProcessTap failed: {err} ({_fourcc(err)!r})"
            )

        def k(key: bytes) -> str:
            return key.decode()

        agg_desc = {
            k(kAudioAggregateDeviceNameKey): "Huske Synced Capture",
            k(kAudioAggregateDeviceUIDKey): f"huske-synced-{uuid.uuid4()}",
            k(kAudioAggregateDeviceIsPrivateKey): 1,
            # The mic drives the clock; the tap is resampled onto it.
            k(kAudioAggregateDeviceMainSubDeviceKey): self._mic.uid,
            k(kAudioAggregateDeviceSubDeviceListKey): [
                {k(kAudioSubDeviceUIDKey): self._mic.uid},
            ],
            k(kAudioAggregateDeviceTapListKey): [
                {
                    k(kAudioSubTapUIDKey): tap_uuid,
                    k(kAudioSubTapDriftCompensationKey): 1,
                },
            ],
            # NOT kAudioAggregateDeviceTapAutoStartKey: with it set, a mic +
            # tap aggregate starts "successfully" but its IOProc is never
            # called (measured on macOS 27.2). The IOProc start drives the tap.
        }
        err, agg_id = AudioHardwareCreateAggregateDevice(agg_desc, None)
        if err != 0 or not agg_id:
            _destroy_tap(tap_id)
            raise SyncedCaptureError(
                f"AudioHardwareCreateAggregateDevice failed: {err} ({_fourcc(err)!r})"
            )

        layout = hal.stream_channels(agg_id)
        if len(layout) != self._mic_buffers + 1:
            _destroy_aggregate(agg_id)
            _destroy_tap(tap_id)
            raise SyncedCaptureError(
                f"unexpected aggregate input layout {layout} for mic layout {mic_layout}"
            )
        rate = hal.nominal_sample_rate(agg_id)
        if not rate:
            _destroy_aggregate(agg_id)
            _destroy_tap(tap_id)
            raise SyncedCaptureError("aggregate device reports no sample rate")
        self._sample_rate = round(rate)

        cb = _AudioDeviceIOProc(self._io_callback)
        proc_id = _AudioDeviceIOProcID()
        err = self._ca.AudioDeviceCreateIOProcID(agg_id, cb, None, ctypes.byref(proc_id))
        if err != 0 or not proc_id.value:
            _destroy_aggregate(agg_id)
            _destroy_tap(tap_id)
            raise SyncedCaptureError(
                f"AudioDeviceCreateIOProcID failed: {err} ({_fourcc(err)!r})"
            )
        err = self._ca.AudioDeviceStart(agg_id, proc_id)
        if err != 0:
            self._ca.AudioDeviceDestroyIOProcID(agg_id, proc_id)
            _destroy_aggregate(agg_id)
            _destroy_tap(tap_id)
            raise SyncedCaptureError(f"AudioDeviceStart failed: {err} ({_fourcc(err)!r})")

        self._tap_id = tap_id
        self._agg_id = agg_id
        self._proc_id = proc_id
        self._cb_obj = cb
        self._on_event(
            "info",
            f"synced capture started: '{self._mic.name}' + system audio on one clock "
            f"({self._sample_rate} Hz)",
        )

    def stop(self, timeout: float = 5.0) -> None:
        del timeout  # API parity with the other backends
        if self._agg_id is None:
            return
        if self._ca is not None and self._proc_id is not None:
            try:
                self._ca.AudioDeviceStop(self._agg_id, self._proc_id)
            except Exception:
                pass
            try:
                self._ca.AudioDeviceDestroyIOProcID(self._agg_id, self._proc_id)
            except Exception:
                pass
        _destroy_aggregate(self._agg_id)
        if self._tap_id is not None:
            _destroy_tap(self._tap_id)
        self._agg_id = None
        self._tap_id = None
        self._proc_id = None
        self._cb_obj = None
        self._on_event("info", "synced capture stopped")

    def drain_available(self) -> list[tuple[NDArrayF32, NDArrayF32, datetime]]:
        with self._lock:
            out = list(self._queue)
            self._queue.clear()
            overflowed, self._overflowed = self._overflowed, False
        if overflowed:
            self._on_event("warn", "synced capture buffer overflow — dropped frames")
        return out


def _as_f32(buf: _AudioBuffer) -> NDArrayF32 | None:
    if buf.mDataByteSize == 0 or not buf.mData:
        return None
    raw = (ctypes.c_ubyte * int(buf.mDataByteSize)).from_address(buf.mData)
    return np.frombuffer(raw, dtype=np.float32)


def _first_channel(buf: _AudioBuffer) -> NDArrayF32 | None:
    """Channel 1 of a (possibly multi-channel, interleaved) mic stream.

    Matches the PortAudio path, which opens the mic with ``channels=1``.
    """
    arr = _as_f32(buf)
    if arr is None:
        return None
    ch = max(int(buf.mNumberChannels), 1)
    if ch == 1:
        return arr.copy()
    return np.ascontiguousarray(arr[::ch], dtype=np.float32)


def _mono(buf: _AudioBuffer) -> NDArrayF32 | None:
    arr = _as_f32(buf)
    if arr is None:
        return None
    ch = max(int(buf.mNumberChannels), 1)
    if ch == 1:
        return arr.copy()
    usable = (arr.size // ch) * ch
    return arr[:usable].reshape(-1, ch).mean(axis=1).astype(np.float32)


def _destroy_tap(tap_id: int) -> None:
    try:
        from CoreAudio import AudioHardwareDestroyProcessTap

        AudioHardwareDestroyProcessTap(tap_id)
    except Exception:
        pass


def _destroy_aggregate(agg_id: int) -> None:
    try:
        from CoreAudio import AudioHardwareDestroyAggregateDevice

        AudioHardwareDestroyAggregateDevice(agg_id)
    except Exception:
        pass
