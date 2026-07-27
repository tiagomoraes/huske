"""Unix-domain-socket control server for external clients (menu bar helper).

Owns the listening socket and a set of connected clients. Inbound JSON
``cmd`` messages are translated to :class:`Command` values and pushed onto
the orchestrator's :class:`CommandChannel`. State updates are broadcast to
all clients via :meth:`ControlServer.broadcast_state`.
"""

from __future__ import annotations

import contextlib
import os
import socket
import threading
from pathlib import Path
from typing import Any

from huske.control import CommandChannel
from huske.ipc.protocol import (
    CommandMessage,
    ControlSnapshot,
    DeviceList,
    decode_message,
    encode_devices,
    encode_snapshot,
)

_ACCEPT_TIMEOUT_SECONDS = 0.5
_RECV_TIMEOUT_SECONDS = 0.5
_BACKLOG = 4


class ControlServer:
    def __init__(
        self,
        socket_path: Path,
        commands: CommandChannel,
        log: Any | None = None,
    ) -> None:
        self._socket_path = socket_path
        self._commands = commands
        self._log = log
        self._listener: socket.socket | None = None
        self._stop = threading.Event()
        self._accept_thread: threading.Thread | None = None
        self._clients_lock = threading.Lock()
        self._clients: list[socket.socket] = []
        self._client_threads: list[threading.Thread] = []
        self._latest_snapshot: bytes | None = None

    @property
    def socket_path(self) -> Path:
        return self._socket_path

    @property
    def connected_clients(self) -> int:
        with self._clients_lock:
            return len(self._clients)

    def start(self) -> None:
        self._socket_path.parent.mkdir(parents=True, exist_ok=True)
        # Stale socket from a prior crash would make bind() fail with EADDRINUSE.
        with contextlib.suppress(FileNotFoundError):
            self._socket_path.unlink()

        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self._socket_path))
        os.chmod(self._socket_path, 0o600)
        listener.listen(_BACKLOG)
        listener.settimeout(_ACCEPT_TIMEOUT_SECONDS)
        self._listener = listener

        self._accept_thread = threading.Thread(
            target=self._accept_loop, name="huske-ipc-accept", daemon=True
        )
        self._accept_thread.start()

    def broadcast_state(self, snap: ControlSnapshot) -> None:
        payload = encode_snapshot(snap)
        self._latest_snapshot = payload
        self._send_to_all(payload)

    def broadcast_devices(self, devices: DeviceList) -> None:
        self._send_to_all(encode_devices(devices))

    def stop(self, timeout: float = 1.0) -> None:
        self._stop.set()
        if self._listener is not None:
            with contextlib.suppress(OSError):
                self._listener.close()
            self._listener = None
        if self._accept_thread is not None:
            self._accept_thread.join(timeout=timeout)
            self._accept_thread = None
        with self._clients_lock:
            for client in self._clients:
                with contextlib.suppress(OSError):
                    client.close()
            self._clients.clear()
        for thread in self._client_threads:
            thread.join(timeout=timeout)
        self._client_threads.clear()
        with contextlib.suppress(FileNotFoundError):
            self._socket_path.unlink()

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _accept_loop(self) -> None:
        listener = self._listener
        assert listener is not None
        while not self._stop.is_set():
            try:
                client, _ = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                # Listener closed during stop().
                return
            client.settimeout(_RECV_TIMEOUT_SECONDS)
            with self._clients_lock:
                self._clients.append(client)
            # Replay the last snapshot so a freshly attached helper paints
            # immediately instead of waiting for the next state change.
            if self._latest_snapshot is not None:
                with contextlib.suppress(OSError):
                    client.sendall(self._latest_snapshot)
            thread = threading.Thread(
                target=self._client_reader,
                args=(client,),
                name="huske-ipc-client",
                daemon=True,
            )
            self._client_threads.append(thread)
            thread.start()

    def _client_reader(self, client: socket.socket) -> None:
        buffer = b""
        while not self._stop.is_set():
            try:
                chunk = client.recv(4096)
            except TimeoutError:
                continue
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                self._handle_line(line.decode("utf-8", errors="replace"))
        self._drop_client(client)

    def _handle_line(self, line: str) -> None:
        try:
            msg = decode_message(line)
        except (ValueError, KeyError) as exc:
            if self._log is not None:
                self._log.warning("ipc_decode_failed", error=str(exc), line=line[:80])
            return
        if isinstance(msg, CommandMessage):
            self._commands.send(msg.command, msg.arg)

    def _drop_client(self, client: socket.socket) -> None:
        with contextlib.suppress(OSError):
            client.close()
        with self._clients_lock:
            if client in self._clients:
                self._clients.remove(client)

    def _send_to_all(self, payload: bytes) -> None:
        dead: list[socket.socket] = []
        with self._clients_lock:
            clients = list(self._clients)
        for client in clients:
            try:
                client.sendall(payload)
            except OSError:
                dead.append(client)
        for client in dead:
            self._drop_client(client)
