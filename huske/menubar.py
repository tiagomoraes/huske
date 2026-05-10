"""macOS menu bar helper.

Runs as a child process spawned by ``huske run``. Connects to the
orchestrator's Unix-domain control socket, renders an ``NSStatusBar`` item
with a small action menu, and translates clicks into command messages on
the wire. Quits automatically when the socket closes (parent died).

The label can be either the literal text ``huske`` (default) or the huske
logo (``--style icon``). A monochrome state badge — recording dot, pause
glyph, or three-dot draining indicator — is always rendered next to the
label so the user knows the recording state at a glance.

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

_ASSETS = Path(__file__).parent / "menubar_assets"
_LOGO_PATH = _ASSETS / "logo.png"
_BADGE_DOT = _ASSETS / "badges" / "dot.png"
_BADGE_PAUSE = _ASSETS / "badges" / "pause.png"
_BADGE_DRAINING = _ASSETS / "badges" / "draining.png"


def run_helper(socket_path: Path, *, style: str = "text") -> int:
    if sys.platform != "darwin":
        print("huske menubar is macOS-only", file=sys.stderr)
        return 2

    try:
        import objc
        from AppKit import (
            NSApplication,
            NSApplicationActivationPolicyAccessory,
            NSImage,
            NSImageLeft,
            NSImageRight,
            NSMenu,
            NSMenuItem,
            NSStatusBar,
            NSTextAttachment,
            NSVariableStatusItemLength,
        )
        from Foundation import (
            NSAttributedString,
            NSMutableAttributedString,
            NSObject,
        )
    except ImportError as exc:  # pragma: no cover — depends on PyObjC AppKit
        print(f"huske menubar requires AppKit (PyObjC): {exc}", file=sys.stderr)
        return 3

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(socket_path))
    except OSError as exc:
        print(f"could not connect to {socket_path}: {exc}", file=sys.stderr)
        return 4

    def _load_template(path: Path):  # type: ignore[no-untyped-def]
        if not path.exists():
            return None
        image = NSImage.alloc().initWithContentsOfFile_(str(path))
        if image is not None:
            image.setTemplate_(True)
        return image

    logo_image = _load_template(_LOGO_PATH)
    badge_recording = _load_template(_BADGE_DOT)
    badge_paused = _load_template(_BADGE_PAUSE)
    badge_stopping = _load_template(_BADGE_DRAINING)

    class HuskeMenuDelegate(NSObject):  # type: ignore[misc]
        def init(self):  # type: ignore[no-untyped-def]
            self = objc.super(HuskeMenuDelegate, self).init()
            if self is None:
                return None
            self._sock = sock
            self._style = style
            self._pending_lock = threading.Lock()
            self._pending_snapshot: ControlSnapshot | None = None
            self._status_item = None
            self._status_label = None
            return self

        @objc.python_method  # type: ignore[untyped-decorator]
        def buildMenu(self) -> None:
            status_bar = NSStatusBar.systemStatusBar()
            self._status_item = status_bar.statusItemWithLength_(NSVariableStatusItemLength)
            self._renderButton(badge=None)

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

        @objc.python_method  # type: ignore[untyped-decorator]
        def _add_action(self, menu, title: str, selector: str) -> None:  # type: ignore[no-untyped-def]
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, selector, "")
            item.setTarget_(self)
            menu.addItem_(item)

        @objc.python_method  # type: ignore[untyped-decorator]
        def _renderButton(self, badge) -> None:  # type: ignore[no-untyped-def]
            button = self._status_item.button()  # type: ignore[union-attr]
            if self._style == "icon":
                # Logo on the left as the primary image; badge appears as a
                # text-attachment inline glyph on its right.
                if logo_image is not None:
                    button.setImage_(logo_image)
                    button.setImagePosition_(NSImageLeft)
                else:
                    button.setImage_(None)
                if badge is not None:
                    button.setAttributedTitle_(self._badge_attributed(badge, leading_space=True))
                else:
                    button.setTitle_("")
            else:
                # Text mode: literal "huske" with the badge as a sibling image.
                button.setTitle_("huske")
                if badge is not None:
                    button.setImage_(badge)
                    button.setImagePosition_(NSImageRight)
                else:
                    button.setImage_(None)

        @objc.python_method  # type: ignore[untyped-decorator]
        def _badge_attributed(self, badge, *, leading_space: bool):  # type: ignore[no-untyped-def]
            attr = NSMutableAttributedString.alloc().init()
            if leading_space:
                attr.appendAttributedString_(
                    NSAttributedString.alloc().initWithString_(" ")
                )
            attachment = NSTextAttachment.alloc().init()
            attachment.setImage_(badge)
            attr.appendAttributedString_(
                NSAttributedString.attributedStringWithAttachment_(attachment)
            )
            return attr

        # -- main-thread methods (selectors must end in `_` for PyObjC) --

        def applySnapshot_(self, _):  # type: ignore[no-untyped-def]
            with self._pending_lock:
                snap = self._pending_snapshot
                self._pending_snapshot = None
            if snap is None:
                return

            if snap.stopping:
                state_text = "draining…"
                badge = badge_stopping
            elif snap.paused:
                state_text = "paused"
                badge = badge_paused
            elif snap.recording:
                state_text = "recording"
                badge = badge_recording
            else:
                state_text = "idle"
                badge = None

            self._renderButton(badge=badge)

            chunk = (
                f"chunk {snap.current_chunk_seq:03d}"
                if snap.current_chunk_seq
                else "no chunk yet"
            )
            queue = f"queue {snap.queue_depth}"
            shots = "screenshots on" if snap.screenshots_enabled else "screenshots off"
            self._status_label.setTitle_(  # type: ignore[union-attr]
                f"{state_text} · {chunk} · {queue} · {shots}"
            )

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

        @objc.python_method  # type: ignore[untyped-decorator]
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
