"""System audio capture via ScreenCaptureKit (macOS 13+).

ScreenCaptureKit emits non-interleaved 32-bit float linear PCM. This module
extracts those buffers in the SCStream sample-handler thread, mixes both
channels down to mono, and exposes them through a thread-safe ring buffer
that the capture coordinator pulls from.

Permission: macOS will prompt for Screen Recording access on first use.
The grant is per-binary-path (the Python interpreter), persisted by TCC.
"""

from __future__ import annotations

import threading
from collections import deque
from collections.abc import Callable
from datetime import datetime

import numpy as np
import numpy.typing as npt
import objc
import ScreenCaptureKit as SCK
from CoreMedia import (
    CMBlockBufferCopyDataBytes,
    CMBlockBufferGetDataLength,
    CMSampleBufferGetDataBuffer,
    CMSampleBufferGetNumSamples,
)
from Foundation import NSObject

_PERMISSION_DENIED_MARKER = "permission denied"


class SystemAudioPermissionError(RuntimeError):
    """Raised when Screen Recording permission isn't granted."""


def check_permission(timeout: float = 5.0) -> bool:
    """Return True if Screen Recording permission has been granted to this process.

    Probes by calling SCShareableContent — if permission is missing, the call
    returns an error and we treat that as "not granted". The first call also
    triggers macOS's prompt dialog if no decision has been recorded yet.
    """
    holder: list[tuple[object, object]] = []
    done = threading.Event()

    def cb(content: object, error: object) -> None:
        holder.append((content, error))
        done.set()

    SCK.SCShareableContent.getShareableContentWithCompletionHandler_(cb)
    if not done.wait(timeout):
        return False
    content, error = holder[0]
    if error is not None:
        return False
    return content is not None and len(content.displays()) > 0  # type: ignore[attr-defined]


class _StreamOutput(NSObject):  # type: ignore[misc]
    """SCStreamOutput delegate. Receives audio CMSampleBuffers."""

    def initWithCallback_(self, callback: Callable[[npt.NDArray[np.float32], datetime], None]):  # type: ignore[no-untyped-def]
        self = objc.super(_StreamOutput, self).init()
        if self is None:
            return None
        self._callback = callback
        return self

    # objc selector: stream:didOutputSampleBuffer:ofType:
    def stream_didOutputSampleBuffer_ofType_(
        self, stream: object, sample_buffer: object, sample_type: int
    ) -> None:
        if sample_type != SCK.SCStreamOutputTypeAudio:
            return
        try:
            block_buf = CMSampleBufferGetDataBuffer(sample_buffer)
            if block_buf is None:
                return
            num_samples = int(CMSampleBufferGetNumSamples(sample_buffer))
            data_len = int(CMBlockBufferGetDataLength(block_buf))
            if num_samples == 0 or data_len == 0:
                return
            status, raw = CMBlockBufferCopyDataBytes(block_buf, 0, data_len, None)
            if status != 0 or not raw:
                return
            arr = np.frombuffer(raw, dtype=np.float32)
            # SCStream emits non-interleaved: bytes are [ch0_planar, ch1_planar, ...].
            # Layout: total floats = num_samples * channels.
            total_floats = arr.shape[0]
            if total_floats % num_samples != 0:
                return  # malformed
            channels = total_floats // num_samples
            if channels < 1:
                return
            if channels == 1:
                mono = arr.copy()
            else:
                # Reshape (channels, num_samples) since planar.
                planar = arr.reshape(channels, num_samples)
                mono = planar.mean(axis=0).astype(np.float32, copy=False).copy()
            now = datetime.now().astimezone()
            self._callback(mono, now)
        except Exception:
            # Never raise out of an Objective-C selector — would crash the runloop.
            return


class SystemAudioStream:
    """Manages an SCStream that captures system audio and feeds mono float32 blocks.

    Lifecycle:
        stream = SystemAudioStream(sample_rate=48000)
        stream.start()    # may raise SystemAudioPermissionError
        ...
        for block, ts in stream.iter_blocks(timeout=0.05): ...
        stream.stop()
    """

    def __init__(
        self,
        sample_rate: int = 48000,
        on_event: Callable[[str, str], None] | None = None,
        max_queued_blocks: int = 256,
    ) -> None:
        self._sample_rate = sample_rate
        self._on_event = on_event or (lambda _s, _m: None)

        self._stream: object | None = None
        self._output: object | None = None
        self._queue: deque[tuple[npt.NDArray[np.float32], datetime]] = deque(
            maxlen=max_queued_blocks
        )
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._last_callback_at: datetime | None = None

    @property
    def last_callback_at(self) -> datetime | None:
        return self._last_callback_at

    def _ingest(self, mono: npt.NDArray[np.float32], when: datetime) -> None:
        with self._cond:
            if len(self._queue) == self._queue.maxlen:
                # Backpressure: drop oldest. Only happens if the consumer has stalled
                # for more than ~max_queued_blocks * block_duration seconds.
                self._queue.popleft()
                self._on_event("warn", "system-audio buffer overflow — dropping frames")
            self._queue.append((mono, when))
            self._last_callback_at = when
            self._cond.notify()

    def _get_default_display(self, timeout: float = 5.0) -> object:
        holder: list[tuple[object, object]] = []
        done = threading.Event()

        def cb(content: object, error: object) -> None:
            holder.append((content, error))
            done.set()

        SCK.SCShareableContent.getShareableContentWithCompletionHandler_(cb)
        if not done.wait(timeout):
            raise SystemAudioPermissionError(
                "Timed out waiting for SCShareableContent — Screen Recording "
                "permission not granted? "
                "Open System Settings → Privacy & Security → Screen Recording, "
                "enable Python, then restart huske."
            )
        content, error = holder[0]
        if error is not None or content is None:
            raise SystemAudioPermissionError(
                f"ScreenCaptureKit refused: {error}. "
                "Grant Screen Recording permission to this Python in "
                "System Settings → Privacy & Security → Screen Recording."
            )
        displays = content.displays()  # type: ignore[attr-defined]
        if not displays or len(displays) == 0:
            raise SystemAudioPermissionError(
                "No displays available for ScreenCaptureKit — permission likely missing."
            )
        return displays[0]

    def start(self) -> None:
        if self._stream is not None:
            return

        display = self._get_default_display()

        filter_ = SCK.SCContentFilter.alloc().initWithDisplay_excludingApplications_exceptingWindows_(
            display, [], []
        )
        config = SCK.SCStreamConfiguration.alloc().init()
        config.setCapturesAudio_(True)
        config.setSampleRate_(self._sample_rate)
        config.setChannelCount_(2)
        config.setExcludesCurrentProcessAudio_(True)
        # Audio-only: keep video size minimal to reduce overhead.
        try:
            config.setWidth_(2)
            config.setHeight_(2)
            config.setMinimumFrameInterval_((1, 1))  # 1 fps
        except Exception:
            pass

        output = _StreamOutput.alloc().initWithCallback_(self._ingest)
        if output is None:
            raise RuntimeError("Failed to allocate SCStreamOutput delegate")

        stream = SCK.SCStream.alloc().initWithFilter_configuration_delegate_(
            filter_, config, None
        )
        ok, err = stream.addStreamOutput_type_sampleHandlerQueue_error_(
            output, SCK.SCStreamOutputTypeAudio, None, None
        )
        if not ok:
            raise RuntimeError(f"addStreamOutput failed: {err}")

        start_done = threading.Event()
        start_error: list[object] = []

        def start_cb(error: object) -> None:
            if error is not None:
                start_error.append(error)
            start_done.set()

        stream.startCaptureWithCompletionHandler_(start_cb)
        if not start_done.wait(10.0):
            raise RuntimeError("SCStream.startCapture timed out")
        if start_error:
            raise RuntimeError(f"SCStream.startCapture error: {start_error[0]}")

        self._stream = stream
        self._output = output
        self._on_event("info", "system audio capture started")

    def stop(self, timeout: float = 5.0) -> None:
        if self._stream is None:
            return
        stop_done = threading.Event()

        def stop_cb(_error: object) -> None:
            stop_done.set()

        self._stream.stopCaptureWithCompletionHandler_(stop_cb)  # type: ignore[attr-defined]
        stop_done.wait(timeout)
        self._stream = None
        self._output = None
        self._on_event("info", "system audio capture stopped")

    def drain_available(self) -> list[tuple[npt.NDArray[np.float32], datetime]]:
        """Pop everything currently queued (non-blocking)."""
        with self._cond:
            out = list(self._queue)
            self._queue.clear()
            return out
