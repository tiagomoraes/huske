"""Local IPC between the orchestrator and external control surfaces.

The orchestrator runs a Unix-domain-socket :class:`ControlServer` that pushes
:class:`ControlSnapshot` updates to connected clients and translates incoming
:class:`Command` messages into ``CommandChannel.send`` calls. The macOS menu
bar helper is one such client.
"""

from huske.ipc.protocol import ControlSnapshot, decode_message, encode_command, encode_snapshot
from huske.ipc.server import ControlServer

__all__ = [
    "ControlServer",
    "ControlSnapshot",
    "decode_message",
    "encode_command",
    "encode_snapshot",
]
