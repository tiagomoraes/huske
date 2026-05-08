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
        """Return the next available character, or None if no key is waiting."""
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
        for ch in data.decode("utf-8", errors="ignore"):
            self._buffer.append(ch)
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
