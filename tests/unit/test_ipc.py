"""Tests for the IPC protocol and ControlServer."""

from __future__ import annotations

import shutil
import socket
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from huske.control import Command, CommandChannel
from huske.ipc.protocol import (
    ControlSnapshot,
    decode_message,
    encode_command,
    encode_snapshot,
)
from huske.ipc.server import ControlServer


@pytest.fixture
def short_tmp() -> Iterator[Path]:
    """Short tmp dir — macOS limits AF_UNIX paths to ~104 chars."""
    path = Path(tempfile.mkdtemp(prefix="hsk"))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def _snap(**overrides: object) -> ControlSnapshot:
    base = dict(
        session_id="20260509T120000_abcd",
        recording=True,
        paused=False,
        stopping=False,
        current_chunk_seq=2,
        queue_depth=1,
        screenshots_enabled=False,
        last_saved_name="120015_abcd0000_001.md",
    )
    base.update(overrides)
    return ControlSnapshot(**base)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Protocol round-trips
# ---------------------------------------------------------------------------


def test_snapshot_round_trip() -> None:
    snap = _snap()
    line = encode_snapshot(snap).decode("utf-8").rstrip("\n")
    decoded = decode_message(line)
    assert decoded == snap


def test_command_round_trip() -> None:
    line = encode_command(Command.PAUSE_RESUME).decode("utf-8").rstrip("\n")
    assert decode_message(line) is Command.PAUSE_RESUME


def test_decode_unknown_type_raises() -> None:
    with pytest.raises(ValueError):
        decode_message('{"type":"bogus"}')


# ---------------------------------------------------------------------------
# Server end-to-end with a fake client
# ---------------------------------------------------------------------------


def _connect(socket_path: Path, timeout: float = 1.0) -> socket.socket:
    deadline = time.monotonic() + timeout
    last_exc: Exception | None = None
    while time.monotonic() < deadline:
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(timeout)
            client.connect(str(socket_path))
            return client
        except OSError as exc:
            last_exc = exc
            time.sleep(0.02)
    raise AssertionError(f"could not connect to {socket_path}: {last_exc}")


def _read_line(sock: socket.socket, timeout: float = 1.0) -> str:
    sock.settimeout(timeout)
    buffer = b""
    while b"\n" not in buffer:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buffer += chunk
    line, _, _ = buffer.partition(b"\n")
    return line.decode("utf-8")


def test_server_broadcasts_state_to_connected_clients(short_tmp: Path) -> None:
    commands = CommandChannel()
    server = ControlServer(short_tmp / "control.sock", commands)
    server.start()
    try:
        client = _connect(server.socket_path)
        try:
            server.broadcast_state(_snap())
            line = _read_line(client)
            assert decode_message(line) == _snap()
        finally:
            client.close()
    finally:
        server.stop()


def test_server_replays_latest_snapshot_to_late_joiner(short_tmp: Path) -> None:
    commands = CommandChannel()
    server = ControlServer(short_tmp / "control.sock", commands)
    server.start()
    try:
        server.broadcast_state(_snap(current_chunk_seq=7))
        client = _connect(server.socket_path)
        try:
            line = _read_line(client)
            decoded = decode_message(line)
            assert isinstance(decoded, ControlSnapshot)
            assert decoded.current_chunk_seq == 7
        finally:
            client.close()
    finally:
        server.stop()


def test_server_translates_client_command_to_channel(short_tmp: Path) -> None:
    commands = CommandChannel()
    server = ControlServer(short_tmp / "control.sock", commands)
    server.start()
    try:
        client = _connect(server.socket_path)
        try:
            client.sendall(encode_command(Command.STOP))
            deadline = time.monotonic() + 1.0
            drained: list[Command] = []
            while time.monotonic() < deadline and not drained:
                drained = commands.drain()
                if not drained:
                    time.sleep(0.02)
            assert drained == [Command.STOP]
        finally:
            client.close()
    finally:
        server.stop()


def test_server_unlinks_socket_on_stop(short_tmp: Path) -> None:
    socket_path = short_tmp / "control.sock"
    server = ControlServer(socket_path, CommandChannel())
    server.start()
    assert socket_path.exists()
    server.stop()
    assert not socket_path.exists()


def test_server_recovers_from_stale_socket(short_tmp: Path) -> None:
    socket_path = short_tmp / "control.sock"
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    socket_path.write_text("stale")  # not a real socket — bind() must replace it.

    server = ControlServer(socket_path, CommandChannel())
    server.start()
    try:
        # If start() did not handle the stale path, _connect would fail.
        client = _connect(socket_path)
        client.close()
    finally:
        server.stop()
