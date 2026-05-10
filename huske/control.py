"""Internal command channel decoupling input sources from the orchestrator.

The orchestrator owns the recording state; producers (TUI keys today, an IPC
server for the menu bar tomorrow) translate user intent into ``Command``
values and push them onto the channel. The orchestrator drains the channel
each tick and dispatches.
"""

from __future__ import annotations

import queue
from enum import StrEnum


class Command(StrEnum):
    PAUSE_RESUME = "pause_resume"
    TOGGLE_SCREENSHOTS = "toggle_screenshots"
    STOP = "stop"
    OPEN_TRANSCRIPTS = "open_transcripts"
    OPEN_LATEST_TRANSCRIPT = "open_latest_transcript"


class CommandChannel:
    """Thread-safe FIFO of ``Command`` values."""

    def __init__(self) -> None:
        self._q: queue.Queue[Command] = queue.Queue()

    def send(self, cmd: Command) -> None:
        self._q.put(cmd)

    def drain(self) -> list[Command]:
        out: list[Command] = []
        while True:
            try:
                out.append(self._q.get_nowait())
            except queue.Empty:
                return out
