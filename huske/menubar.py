"""macOS menu bar helper.

Runs as a child process spawned by ``huske run``. Connects to the
orchestrator's Unix-domain control socket, renders an ``NSStatusBar`` icon
with a small action menu, and translates clicks into command messages on
the wire. Quits automatically when the socket closes (parent died).

This module imports AppKit lazily so non-macOS builds can still import the
:mod:`huske` package without a hard dependency on PyObjC AppKit bindings.
"""

from __future__ import annotations

import socket
import sys
import threading
from pathlib import Path

from huske.control import Command
from huske.ipc.protocol import (
    ControlSnapshot,
    decode_message,
    encode_command,
)

# State badge appended next to the icon. Empty string when recording/idle so
# the icon stands alone; only paused/stopping states surface a glyph.
_BADGE_RECORDING = ""
_BADGE_IDLE = ""
_BADGE_PAUSED = " ⏸"
_BADGE_STOPPING = " ⏳"

_ICON_PATH = Path(__file__).parent / "menubar_assets" / "logo.png"


def run_helper(socket_path: Path) -> int:
    if sys.platform != "darwin":
        print("huske menubar is macOS-only", file=sys.stderr)
        return 2

    try:
        import objc
        from AppKit import (
            NSApplication,
            NSApplicationActivationPolicyAccessory,
            NSImage,
            NSMenu,
            NSMenuItem,
            NSStatusBar,
            NSVariableStatusItemLength,
        )
        from Foundation import NSObject
    except ImportError as exc:  # pragma: no cover — depends on PyObjC AppKit
        print(f"huske menubar requires AppKit (PyObjC): {exc}", file=sys.stderr)
        return 3

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(socket_path))
    except OSError as exc:
        print(f"could not connect to {socket_path}: {exc}", file=sys.stderr)
        return 4

    class HuskeMenuDelegate(NSObject):  # type: ignore[misc]
        def init(self):  # type: ignore[no-untyped-def]
            self = objc.super(HuskeMenuDelegate, self).init()
            if self is None:
                return None
            self._sock = sock
            self._pending_lock = threading.Lock()
            self._pending_snapshot: ControlSnapshot | None = None
            self._status_item = None
            self._status_label = None
            return self

        @objc.python_method
        def buildMenu(self) -> None:
            status_bar = NSStatusBar.systemStatusBar()
            self._status_item = status_bar.statusItemWithLength_(NSVariableStatusItemLength)
            button = self._status_item.button()
            image = NSImage.alloc().initWithContentsOfFile_(str(_ICON_PATH))
            if image is not None:
                image.setTemplate_(True)
                button.setImage_(image)
            button.setTitle_(_BADGE_IDLE)

            menu = NSMenu.alloc().init()
            self._status_label = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Waiting for state…", None, ""
            )
            self._status_label.setEnabled_(False)
            menu.addItem_(self._status_label)
            menu.addItem_(NSMenuItem.separatorItem())
            self._add_action(menu, "Pause / Resume", "pauseResume:")
            self._add_action(menu, "Toggle screenshots", "toggleScreenshots:")
            menu.addItem_(NSMenuItem.separatorItem())
            self._add_action(menu, "Open transcripts folder", "openTranscripts:")
            self._add_action(menu, "Open latest transcript", "openLatestTranscript:")
            menu.addItem_(NSMenuItem.separatorItem())
            self._add_action(menu, "Stop recording", "stop:")
            self._status_item.setMenu_(menu)

        @objc.python_method
        def _add_action(self, menu, title: str, selector: str) -> None:  # type: ignore[no-untyped-def]
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, selector, "")
            item.setTarget_(self)
            menu.addItem_(item)

        # -- main-thread methods (selectors must end in `_` for PyObjC) --

        def applySnapshot_(self, _):  # type: ignore[no-untyped-def]
            with self._pending_lock:
                snap = self._pending_snapshot
                self._pending_snapshot = None
            if snap is None:
                return
            if snap.stopping:
                badge = _BADGE_STOPPING
            elif snap.paused:
                badge = _BADGE_PAUSED
            elif snap.recording:
                badge = _BADGE_RECORDING
            else:
                badge = _BADGE_IDLE
            self._status_item.button().setTitle_(badge)

            if snap.stopping:
                state = "stopping…"
            elif snap.paused:
                state = "paused"
            elif snap.recording:
                state = "recording"
            else:
                state = "idle"
            chunk = f"chunk {snap.current_chunk_seq:03d}" if snap.current_chunk_seq else "no chunk yet"
            queue = f"queue {snap.queue_depth}"
            shots = "screenshots on" if snap.screenshots_enabled else "screenshots off"
            self._status_label.setTitle_(f"{state} · {chunk} · {queue} · {shots}")

        def terminateApp_(self, _):  # type: ignore[no-untyped-def]
            NSApplication.sharedApplication().terminate_(self)

        # -- menu actions --

        def pauseResume_(self, _):  # type: ignore[no-untyped-def]
            self._send(Command.PAUSE_RESUME)

        def toggleScreenshots_(self, _):  # type: ignore[no-untyped-def]
            self._send(Command.TOGGLE_SCREENSHOTS)

        def openTranscripts_(self, _):  # type: ignore[no-untyped-def]
            self._send(Command.OPEN_TRANSCRIPTS)

        def openLatestTranscript_(self, _):  # type: ignore[no-untyped-def]
            self._send(Command.OPEN_LATEST_TRANSCRIPT)

        def stop_(self, _):  # type: ignore[no-untyped-def]
            self._send(Command.STOP)
            # Helper exits when the orchestrator closes the socket.

        @objc.python_method
        def _send(self, cmd: Command) -> None:
            try:
                self._sock.sendall(encode_command(cmd))
            except OSError:
                pass

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    delegate = HuskeMenuDelegate.alloc().init()
    delegate.buildMenu()

    def reader() -> None:
        buffer = b""
        while True:
            try:
                chunk = sock.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = decode_message(line.decode("utf-8", errors="replace"))
                except (ValueError, KeyError):
                    continue
                if isinstance(msg, ControlSnapshot):
                    with delegate._pending_lock:
                        delegate._pending_snapshot = msg
                    delegate.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "applySnapshot:", None, False
                    )
        delegate.performSelectorOnMainThread_withObject_waitUntilDone_(
            "terminateApp:", None, False
        )

    threading.Thread(target=reader, name="huske-menubar-reader", daemon=True).start()
    app.run()
    return 0
