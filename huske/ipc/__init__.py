"""Local IPC between the orchestrator and external control surfaces.

The orchestrator runs a Unix-domain-socket :class:`ControlServer` that pushes
:class:`ControlSnapshot` updates to connected clients and translates incoming
:class:`CommandMessage` lines into ``CommandChannel.send`` calls. Clients are
the bundled macOS menu bar helper and the native macOS app (``macos/``).
"""

from huske.ipc.protocol import (
    CommandMessage,
    ControlSnapshot,
    DeviceList,
    InputDeviceEntry,
    decode_message,
    encode_command,
    encode_devices,
    encode_snapshot,
)
from huske.ipc.server import ControlServer

__all__ = [
    "CommandMessage",
    "ControlServer",
    "ControlSnapshot",
    "DeviceList",
    "InputDeviceEntry",
    "decode_message",
    "encode_command",
    "encode_devices",
    "encode_snapshot",
]
