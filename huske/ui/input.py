"""Small terminal key reader for the live UI."""

from __future__ import annotations

import os
import select
import sys
import termios
import tty
from collections import deque
from types import TracebackType
from typing import TextIO


class TerminalKeyReader:
    """Read single-character commands without waiting for Enter.

    The reader only enables itself when stdin is a TTY. It uses cbreak mode
    rather than raw mode so Ctrl+C keeps the normal signal behavior.
    """

    def __init__(self, stream: TextIO | None = None) -> None:
        self._stream = stream or sys.stdin
        self._fd: int | None = None
        self._old_attrs: list[int | list[bytes | int]] | None = None
        self._buffer: deque[str] = deque()

    def __enter__(self) -> TerminalKeyReader:
        if not self._stream.isatty():
            return self
        self._fd = self._stream.fileno()
        self._old_attrs = termios.tcgetattr(self._fd)
        tty.setcbreak(self._fd)
        return self

    def read_key(self) -> str | None:
        """Return the next available key, or None if no key is waiting.

        Most keys are returned as a single character. CSI escape sequences
        (e.g. ``\\x1b[A`` for the Up arrow) are coalesced into one token so
        callers can match arrow keys without race-prone state machines.
        Bare Esc still arrives as ``\\x1b`` because the terminal sends it as
        a one-byte packet.
        """
        if self._buffer:
            return self._buffer.popleft()
        if self._fd is None:
            return None
        try:
            readable, _, _ = select.select([self._fd], [], [], 0)
        except OSError:
            return None
        if not readable:
            return None
        try:
            data = os.read(self._fd, 32)
        except OSError:
            return None
        text = data.decode("utf-8", errors="ignore")
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b" and i + 1 < len(text) and text[i + 1] == "[":
                # CSI: ESC '[' params* final-byte (0x40..0x7E).
                j = i + 2
                while j < len(text):
                    cj = text[j]
                    if 0x40 <= ord(cj) <= 0x7E:
                        j += 1
                        break
                    j += 1
                self._buffer.append(text[i:j])
                i = j
            else:
                self._buffer.append(ch)
                i += 1
        if self._buffer:
            return self._buffer.popleft()
        return None

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        if self._fd is not None and self._old_attrs is not None:
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_attrs)
        self._fd = None
        self._old_attrs = None
        self._buffer.clear()
