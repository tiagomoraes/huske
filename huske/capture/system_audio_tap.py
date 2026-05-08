"""System audio capture via Core Audio process tap (macOS 14.4+).

Why this exists alongside ``system_audio.py``: ScreenCaptureKit can be
silently stopped by macOS when another app starts a conflicting capture
(e.g. Google Meet's screen sharing). The Core Audio Process Tap API is
decoupled from screen capture and survives those scenarios.

Implementation note: the high-level Tap and AggregateDevice creation goes
through PyObjC (where the bindings work cleanly), but the per-device
IOProc registration and start/stop go through ctypes — PyObjC's bridge
for ``AudioDeviceIOProcID`` (an opaque function pointer typedef) and the
in/out + variable-length-array shape of ``AudioObjectGetPropertyData``
are incomplete on the CoreAudio side, so we sidestep them.

Permission: macOS may prompt for "Audio Capture" or screen-recording
adjacent permissions on first use, depending on the OS minor version.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import platform
import threading
import uuid
from collections import deque
from collections.abc import Callable
from datetime import datetime

import numpy as np

_PROCESS_TAP_MIN_VERSION = (14, 4)


def is_supported() -> bool:
    """Return True iff this platform can run the Core Audio tap backend.

    macOS 14.4+ introduced ``AudioHardwareCreateProcessTap``. We also need
    PyObjC's CoreAudio framework with the Tap-related symbols compiled in.
    """
    if platform.system() != "Darwin":
        return False
    try:
        ver = tuple(int(x) for x in platform.mac_ver()[0].split(".")[:2])
    except (ValueError, IndexError):
        return False
    if ver < _PROCESS_TAP_MIN_VERSION:
        return False
    try:
        from CoreAudio import (  # noqa: F401
            AudioHardwareCreateAggregateDevice,
            AudioHardwareCreateProcessTap,
            CATapDescription,
        )
    except ImportError:
        return False
    return True


# --- ctypes structs for AudioBufferList / AudioTimeStamp --------------------


class _SMPTETime(ctypes.Structure):
    _fields_ = [
        ("mSubframes", ctypes.c_int16),
        ("mSubframeDivisor", ctypes.c_int16),
        ("mCounter", ctypes.c_uint32),
        ("mType", ctypes.c_uint32),
        ("mFlags", ctypes.c_uint32),
        ("mHours", ctypes.c_int16),
        ("mMinutes", ctypes.c_int16),
        ("mSeconds", ctypes.c_int16),
        ("mFrames", ctypes.c_int16),
    ]


class _AudioTimeStamp(ctypes.Structure):
    _fields_ = [
        ("mSampleTime", ctypes.c_double),
        ("mHostTime", ctypes.c_uint64),
        ("mRateScalar", ctypes.c_double),
        ("mWordClockTime", ctypes.c_uint64),
        ("mSMPTETime", _SMPTETime),
        ("mFlags", ctypes.c_uint32),
        ("mReserved", ctypes.c_uint32),
    ]


class _AudioBuffer(ctypes.Structure):
    _fields_ = [
        ("mNumberChannels", ctypes.c_uint32),
        ("mDataByteSize", ctypes.c_uint32),
        ("mData", ctypes.c_void_p),
    ]


class _AudioBufferList(ctypes.Structure):
    _fields_ = [
        ("mNumberBuffers", ctypes.c_uint32),
        ("mBuffers", _AudioBuffer * 1),  # variable-length tail
    ]


_AudioDeviceIOProcID = ctypes.c_void_p
_AudioDeviceIOProc = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_uint32,
    ctypes.POINTER(_AudioTimeStamp),
    ctypes.POINTER(_AudioBufferList),
    ctypes.POINTER(_AudioTimeStamp),
    ctypes.POINTER(_AudioBufferList),
    ctypes.POINTER(_AudioTimeStamp),
    ctypes.c_void_p,
)


def _load_coreaudio() -> ctypes.CDLL:
    path = ctypes.util.find_library("CoreAudio")
    if not path:
        raise RuntimeError("CoreAudio framework not found")
    lib = ctypes.CDLL(path)
    lib.AudioDeviceCreateIOProcID.argtypes = [
        ctypes.c_uint32,
        _AudioDeviceIOProc,
        ctypes.c_void_p,
        ctypes.POINTER(_AudioDeviceIOProcID),
    ]
    lib.AudioDeviceCreateIOProcID.restype = ctypes.c_int32
    lib.AudioDeviceDestroyIOProcID.argtypes = [ctypes.c_uint32, _AudioDeviceIOProcID]
    lib.AudioDeviceDestroyIOProcID.restype = ctypes.c_int32
    lib.AudioDeviceStart.argtypes = [ctypes.c_uint32, _AudioDeviceIOProcID]
    lib.AudioDeviceStart.restype = ctypes.c_int32
    lib.AudioDeviceStop.argtypes = [ctypes.c_uint32, _AudioDeviceIOProcID]
    lib.AudioDeviceStop.restype = ctypes.c_int32
    return lib


def _fourcc(err: int) -> str:
    err32 = err & 0xFFFFFFFF
    try:
        return err32.to_bytes(4, "big").decode("ascii", "replace")
    except OverflowError:
        return f"{err}"


class CoreAudioTapPermissionError(RuntimeError):
    """Raised when the OS refuses to create the tap or aggregate device."""


class CoreAudioTapStream:
    """System audio capture via Core Audio process tap.

    Mirrors the public surface of ``SystemAudioStream`` so the coordinator
    can pick a backend without changing how it pulls samples.
    """

    def __init__(
        self,
        sample_rate: int = 48000,
        on_event: Callable[[str, str], None] | None = None,
        max_queued_blocks: int = 256,
    ) -> None:
        self._sample_rate = sample_rate
        self._on_event = on_event or (lambda _s, _m: None)

        self._tap_id: int | None = None
        self._agg_id: int | None = None
        self._proc_id: ctypes.c_void_p | None = None
        # Hold a reference to the CFUNCTYPE callback object so the GC
        # doesn't free it while CoreAudio is still calling into it.
        self._cb_obj: object | None = None
        self._ca: ctypes.CDLL | None = None

        self._queue: deque[tuple[np.ndarray, datetime]] = deque(maxlen=max_queued_blocks)
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._last_callback_at: datetime | None = None
        self._observed_rate: int | None = None
        self._rate_warned = False

    @property
    def last_callback_at(self) -> datetime | None:
        return self._last_callback_at

    @property
    def observed_sample_rate(self) -> int | None:
        return self._observed_rate

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
        # Real-time thread — keep this short and never raise.
        try:
            if not in_input:
                return 0
            bl = in_input.contents
            n = int(bl.mNumberBuffers)
            if n == 0:
                return 0
            bufs = ctypes.cast(
                ctypes.addressof(bl.mBuffers),
                ctypes.POINTER(_AudioBuffer * n),
            ).contents
            now = datetime.now().astimezone()
            for i in range(n):
                b = bufs[i]
                if b.mDataByteSize == 0 or not b.mData:
                    continue
                channels = max(int(b.mNumberChannels), 1)
                byte_arr = (ctypes.c_ubyte * int(b.mDataByteSize)).from_address(b.mData)
                arr = np.frombuffer(byte_arr, dtype=np.float32).copy()
                if arr.size == 0:
                    continue
                if channels == 1:
                    mono = arr
                else:
                    # Tap is requested mono; if multi-channel slips in,
                    # average across channels (interleaved layout).
                    try:
                        mono = arr.reshape(-1, channels).mean(axis=1).astype(
                            np.float32, copy=False
                        )
                    except ValueError:
                        continue
                with self._cond:
                    if len(self._queue) == self._queue.maxlen:
                        self._queue.popleft()
                        self._on_event(
                            "warn", "system-audio buffer overflow — dropping frames"
                        )
                    self._queue.append((mono, now))
                    self._last_callback_at = now
                    self._cond.notify()
        except Exception:
            # Never propagate from a CoreAudio real-time callback.
            return 0
        return 0

    def start(self) -> None:
        if self._tap_id is not None:
            return
        if not is_supported():
            raise CoreAudioTapPermissionError(
                "Core Audio process tap is not supported on this platform."
            )

        from CoreAudio import (
            AudioHardwareCreateAggregateDevice,
            AudioHardwareCreateProcessTap,
            CATapDescription,
            kAudioAggregateDeviceIsPrivateKey,
            kAudioAggregateDeviceNameKey,
            kAudioAggregateDeviceTapListKey,
            kAudioAggregateDeviceUIDKey,
            kAudioSubTapUIDKey,
        )

        self._ca = _load_coreaudio()

        desc = CATapDescription.alloc().initMonoGlobalTapButExcludeProcesses_([])
        desc.setName_("huske-system-audio")
        desc.setPrivate_(True)
        tap_uuid = str(desc.UUID())

        err, tap_id = AudioHardwareCreateProcessTap(desc, None)
        if err != 0 or not tap_id:
            raise CoreAudioTapPermissionError(
                f"AudioHardwareCreateProcessTap failed: {err} ({_fourcc(err)!r}). "
                "If macOS prompted for permission, grant it and restart huske."
            )

        agg_uid = f"huske-aggregate-{uuid.uuid4()}"
        agg_desc = {
            kAudioAggregateDeviceNameKey.decode(): "Huske Aggregate (Tap)",
            kAudioAggregateDeviceUIDKey.decode(): agg_uid,
            kAudioAggregateDeviceIsPrivateKey.decode(): 1,
            kAudioAggregateDeviceTapListKey.decode(): [
                {kAudioSubTapUIDKey.decode(): tap_uuid},
            ],
        }
        err, agg_id = AudioHardwareCreateAggregateDevice(agg_desc, None)
        if err != 0 or not agg_id:
            self._destroy_tap(tap_id)
            raise CoreAudioTapPermissionError(
                f"AudioHardwareCreateAggregateDevice failed: {err} ({_fourcc(err)!r})"
            )

        cb = _AudioDeviceIOProc(self._io_callback)
        proc_id = _AudioDeviceIOProcID()
        err = self._ca.AudioDeviceCreateIOProcID(
            agg_id, cb, None, ctypes.byref(proc_id)
        )
        if err != 0 or not proc_id.value:
            self._destroy_aggregate(agg_id)
            self._destroy_tap(tap_id)
            raise CoreAudioTapPermissionError(
                f"AudioDeviceCreateIOProcID failed: {err} ({_fourcc(err)!r})"
            )

        err = self._ca.AudioDeviceStart(agg_id, proc_id)
        if err != 0:
            self._ca.AudioDeviceDestroyIOProcID(agg_id, proc_id)
            self._destroy_aggregate(agg_id)
            self._destroy_tap(tap_id)
            raise CoreAudioTapPermissionError(
                f"AudioDeviceStart failed: {err} ({_fourcc(err)!r})"
            )

        self._tap_id = tap_id
        self._agg_id = agg_id
        self._proc_id = proc_id
        self._cb_obj = cb
        self._on_event("info", "system audio capture started (core-audio tap)")

    def stop(self, timeout: float = 5.0) -> None:
        # timeout kept for API parity with SystemAudioStream; ctypes
        # AudioDeviceStop is synchronous and fast.
        del timeout
        if self._tap_id is None:
            return
        if self._ca is not None and self._agg_id is not None and self._proc_id is not None:
            try:
                self._ca.AudioDeviceStop(self._agg_id, self._proc_id)
            except Exception:
                pass
            try:
                self._ca.AudioDeviceDestroyIOProcID(self._agg_id, self._proc_id)
            except Exception:
                pass
        if self._agg_id is not None:
            self._destroy_aggregate(self._agg_id)
        if self._tap_id is not None:
            self._destroy_tap(self._tap_id)
        self._tap_id = None
        self._agg_id = None
        self._proc_id = None
        self._cb_obj = None
        self._on_event("info", "system audio capture stopped (core-audio tap)")

    def drain_available(self) -> list[tuple[np.ndarray, datetime]]:
        with self._cond:
            out = list(self._queue)
            self._queue.clear()
            return out

    @staticmethod
    def _destroy_tap(tap_id: int) -> None:
        try:
            from CoreAudio import AudioHardwareDestroyProcessTap

            AudioHardwareDestroyProcessTap(tap_id)
        except Exception:
            pass

    @staticmethod
    def _destroy_aggregate(agg_id: int) -> None:
        try:
            from CoreAudio import AudioHardwareDestroyAggregateDevice

            AudioHardwareDestroyAggregateDevice(agg_id)
        except Exception:
            pass
