"""JSON-line wire protocol between the orchestrator and the menu bar helper.

Two message kinds:

- ``{"type": "state", ...}`` — the server pushes a :class:`ControlSnapshot`.
- ``{"type": "cmd", "name": "<command>"}`` — the client sends a command.

Each message is a single line of UTF-8 JSON terminated by ``\\n``.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass

from huske.control import Command


@dataclass(frozen=True)
class ControlSnapshot:
    """Read-only view of the orchestrator state surfaced to the menu bar."""

    session_id: str
    recording: bool
    paused: bool
    stopping: bool
    current_chunk_seq: int
    queue_depth: int
    screenshots_enabled: bool
    last_saved_name: str | None


def encode_snapshot(snap: ControlSnapshot) -> bytes:
    payload = {"type": "state", **asdict(snap)}
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")


def encode_command(cmd: Command) -> bytes:
    payload = {"type": "cmd", "name": cmd.value}
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")


def decode_message(line: str) -> ControlSnapshot | Command:
    """Parse a single JSON line. Raises ``ValueError`` on unknown messages."""
    obj = json.loads(line)
    kind = obj.get("type")
    if kind == "state":
        return ControlSnapshot(
            session_id=obj["session_id"],
            recording=obj["recording"],
            paused=obj["paused"],
            stopping=obj["stopping"],
            current_chunk_seq=obj["current_chunk_seq"],
            queue_depth=obj["queue_depth"],
            screenshots_enabled=obj["screenshots_enabled"],
            last_saved_name=obj["last_saved_name"],
        )
    if kind == "cmd":
        return Command(obj["name"])
    raise ValueError(f"unknown message type: {kind!r}")
