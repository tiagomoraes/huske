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
    TOGGLE_DISTILL = "toggle_distill"
    STOP = "stop"
    OPEN_TRANSCRIPTS = "open_transcripts"
    OPEN_LATEST_TRANSCRIPT = "open_latest_transcript"
    # Carries an argument (device index or name) — see ipc/protocol.py.
    SET_INPUT_DEVICE = "set_input_device"
    # Asks the orchestrator to broadcast a DeviceList to control clients.
    REQUEST_DEVICES = "request_devices"


CommandArg = str | int | None


class CommandChannel:
    """Thread-safe FIFO of ``(Command, arg)`` pairs.

    Most commands carry no argument; producers may call ``send(cmd)`` and the
    arg defaults to ``None``.
    """

    def __init__(self) -> None:
        self._q: queue.Queue[tuple[Command, CommandArg]] = queue.Queue()

    def send(self, cmd: Command, arg: CommandArg = None) -> None:
        self._q.put((cmd, arg))

    def drain(self) -> list[tuple[Command, CommandArg]]:
        out: list[tuple[Command, CommandArg]] = []
        while True:
            try:
                out.append(self._q.get_nowait())
            except queue.Empty:
                return out
