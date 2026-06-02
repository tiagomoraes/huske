"""Periodic screenshot capture using the macOS ``screencapture`` tool.

Runs on its own daemon thread, completely independent of the audio pipeline.
Each tick writes one JPEG per attached display to
``~/huske/screenshots/YYYY-MM-DD/<session_id>/HHMMSS_dN.jpg``.

Why ``screencapture``: it's built into macOS, ships native JPEG encoding, and
uses Screen Recording permission. System audio may use a different Core Audio
permission on newer macOS versions, so screenshots can still trigger their own
prompt. ``screencapture`` writes "1 file per screen" when given multiple file
paths — we pass ``screenshots_max_displays`` paths and only the existing
displays produce files. No external dep, no probing required.
"""

from __future__ import annotations

import shutil
import subprocess
import threading
from collections.abc import Callable
from datetime import datetime
from typing import Literal

from huske import paths
from huske.config import RuntimeConfig

EventSeverity = Literal["info", "warn", "error"]
EventCallback = Callable[[EventSeverity, str], None]


_SCREENCAPTURE = "screencapture"
_CAPTURE_TIMEOUT_SECONDS = 15.0


class ScreenshotCapturer:
    """Background thread that snapshots the screen on a fixed cadence."""

    def __init__(
        self,
        cfg: RuntimeConfig,
        session_id: str,
        on_event: EventCallback | None = None,
    ) -> None:
        self._cfg = cfg
        self._session_id = session_id
        self._on_event: EventCallback = on_event or (lambda _s, _m: None)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._captures = 0
        self._last_capture_at: datetime | None = None

    @property
    def captures(self) -> int:
        return self._captures

    @property
    def last_capture_at(self) -> datetime | None:
        return self._last_capture_at

    @property
    def alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        if self._thread is not None:
            return
        if shutil.which(_SCREENCAPTURE) is None:
            self._on_event(
                "warn",
                "screenshots disabled: `screencapture` not found on PATH "
                "(this feature requires macOS)",
            )
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, name="huske-screenshots", daemon=True
        )
        self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=timeout)
            self._thread = None

    def _run(self) -> None:
        # Take an immediate first capture so the user sees state right away,
        # then wait for the configured interval between successive captures.
        first = True
        while not self._stop.is_set():
            if not first:
                if self._stop.wait(self._cfg.screenshots_interval_seconds):
                    break
            first = False
            try:
                self._capture_once(datetime.now().astimezone())
            except subprocess.TimeoutExpired:
                self._on_event("warn", "screenshot capture timed out")
            except Exception as exc:
                self._on_event("warn", f"screenshot capture failed: {exc}")

    def _capture_once(self, now: datetime) -> int:
        target_dir = paths.screenshots_session_dir(self._cfg, self._session_id, now)
        target_dir.mkdir(parents=True, exist_ok=True)

        targets = [
            target_dir / paths.screenshot_filename(now, i)
            for i in range(1, self._cfg.screenshots_max_displays + 1)
        ]
        cmd = [_SCREENCAPTURE, "-x", "-t", "jpg", *(str(t) for t in targets)]
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=_CAPTURE_TIMEOUT_SECONDS,
            check=False,
        )
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(
                f"screencapture exit {result.returncode}: {stderr or '<no stderr>'}"
            )

        written = sum(1 for t in targets if t.exists() and t.stat().st_size > 0)
        if written == 0:
            raise RuntimeError("screencapture produced no files (Screen Recording permission?)")

        self._captures += 1
        self._last_capture_at = now
        return written
