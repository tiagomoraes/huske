"""JSON-line wire protocol between the orchestrator and external UIs.

Clients are the bundled menu bar helper and the native macOS app. Message
kinds:

- ``{"type": "state", ...}`` — the server pushes a :class:`ControlSnapshot`.
- ``{"type": "cmd", "name": "<command>", "arg": <value>?}`` — the client
  sends a :class:`CommandMessage`; ``arg`` is optional and command-specific
  (today only ``set_input_device`` carries one).
- ``{"type": "devices", ...}`` — the server answers ``request_devices``
  with a :class:`DeviceList`.

Each message is a single line of UTF-8 JSON terminated by ``\\n``.

Compatibility rule: snapshot fields added after v1 all have defaults, so a
client decoding an older server's lines (or vice versa) degrades gracefully
instead of failing. Never remove or retype an existing field.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from typing import Any

from huske.control import Command


@dataclass(frozen=True)
class ControlSnapshot:
    """Read-only view of the orchestrator state surfaced to UI clients."""

    session_id: str
    recording: bool
    paused: bool
    stopping: bool
    current_chunk_seq: int
    queue_depth: int
    screenshots_enabled: bool
    distill_enabled: bool
    last_saved_name: str | None
    # -- v2 fields (defaults keep v1 lines decodable) -----------------------
    peak_mic_db: float = -120.0
    peak_system_db: float = -120.0
    chunk_started_at: str | None = None  # ISO 8601
    next_rotation_at: str | None = None  # ISO 8601 (chunk cap deadline)
    session_started_at: str | None = None  # ISO 8601
    huske_version: str = ""
    output_root: str | None = None
    last_saved_path: str | None = None
    screenshots_count: int = 0
    input_device_name: str | None = None
    warnings: dict[str, str] = field(default_factory=dict)
    # Recent orchestrator events, oldest first:
    # ``{"ts": iso8601, "severity": "info"|"warn"|"error", "message": str}``.
    events: list[dict[str, str]] = field(default_factory=list)
    # v3 — process RSS in MiB (0 when unknown). Add-only so older clients ignore it.
    asr_rss_mb: float = 0.0
    distill_rss_mb: float = 0.0
    engine_rss_mb: float = 0.0


@dataclass(frozen=True)
class CommandMessage:
    """A client-issued command, optionally carrying one argument."""

    command: Command
    arg: str | int | None = None


@dataclass(frozen=True)
class InputDeviceEntry:
    index: int
    name: str
    channels: int
    sample_rate: float


@dataclass(frozen=True)
class DeviceList:
    """Server answer to ``request_devices``: selectable microphone inputs."""

    devices: tuple[InputDeviceEntry, ...]
    current_index: int | None


def _dumps(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")


def encode_snapshot(snap: ControlSnapshot) -> bytes:
    return _dumps({"type": "state", **asdict(snap)})


def encode_command(cmd: Command, arg: str | int | None = None) -> bytes:
    payload: dict[str, Any] = {"type": "cmd", "name": cmd.value}
    if arg is not None:
        payload["arg"] = arg
    return _dumps(payload)


def encode_devices(devices: DeviceList) -> bytes:
    return _dumps(
        {
            "type": "devices",
            "devices": [asdict(d) for d in devices.devices],
            "current_index": devices.current_index,
        }
    )


def decode_message(line: str) -> ControlSnapshot | CommandMessage | DeviceList:
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
            distill_enabled=obj["distill_enabled"],
            last_saved_name=obj["last_saved_name"],
            peak_mic_db=float(obj.get("peak_mic_db", -120.0)),
            peak_system_db=float(obj.get("peak_system_db", -120.0)),
            chunk_started_at=obj.get("chunk_started_at"),
            next_rotation_at=obj.get("next_rotation_at"),
            session_started_at=obj.get("session_started_at"),
            huske_version=obj.get("huske_version", ""),
            output_root=obj.get("output_root"),
            last_saved_path=obj.get("last_saved_path"),
            screenshots_count=int(obj.get("screenshots_count", 0)),
            input_device_name=obj.get("input_device_name"),
            warnings=dict(obj.get("warnings") or {}),
            events=list(obj.get("events") or []),
            asr_rss_mb=float(obj.get("asr_rss_mb", 0.0) or 0.0),
            distill_rss_mb=float(obj.get("distill_rss_mb", 0.0) or 0.0),
            engine_rss_mb=float(obj.get("engine_rss_mb", 0.0) or 0.0),
        )
    if kind == "cmd":
        arg = obj.get("arg")
        if arg is not None and not isinstance(arg, (str, int)):
            raise ValueError(f"unsupported command arg type: {type(arg).__name__}")
        return CommandMessage(command=Command(obj["name"]), arg=arg)
    if kind == "devices":
        return DeviceList(
            devices=tuple(
                InputDeviceEntry(
                    index=int(d["index"]),
                    name=str(d["name"]),
                    channels=int(d.get("channels", 1)),
                    sample_rate=float(d.get("sample_rate", 48000.0)),
                )
                for d in obj.get("devices") or []
            ),
            current_index=obj.get("current_index"),
        )
    raise ValueError(f"unknown message type: {kind!r}")
