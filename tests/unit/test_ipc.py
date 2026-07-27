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
        distill_enabled=False,
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


def test_snapshot_v2_fields_round_trip() -> None:
    snap = _snap(
        peak_mic_db=-23.5,
        peak_system_db=-41.0,
        chunk_started_at="2026-05-09T12:00:00-03:00",
        next_rotation_at="2026-05-09T12:30:00-03:00",
        session_started_at="2026-05-09T11:59:00-03:00",
        huske_version="0.11.0",
        output_root="/Users/me/huske/transcripts",
        last_saved_path="/Users/me/huske/transcripts/2026-05-09/120015_abcd0000_001.md",
        screenshots_count=4,
        input_device_name="MacBook Pro Microphone",
        warnings={"heartbeat": "no audio for 6s"},
        events=[
            {"ts": "2026-05-09T12:00:01-03:00", "severity": "info", "message": "hi"}
        ],
    )
    line = encode_snapshot(snap).decode("utf-8").rstrip("\n")
    assert decode_message(line) == snap


def test_v1_snapshot_line_decodes_with_defaults() -> None:
    """A wire line from a pre-v2 server must still decode (defaults fill in)."""
    v1_line = (
        '{"type":"state","session_id":"20260509T120000_abcd","recording":true,'
        '"paused":false,"stopping":false,"current_chunk_seq":2,"queue_depth":1,'
        '"screenshots_enabled":false,"distill_enabled":false,'
        '"last_saved_name":"120015_abcd0000_001.md"}'
    )
    decoded = decode_message(v1_line)
    assert isinstance(decoded, ControlSnapshot)
    assert decoded.peak_mic_db == -120.0
    assert decoded.warnings == {}
    assert decoded.events == []
    assert decoded.input_device_name is None


def test_command_round_trip() -> None:
    line = encode_command(Command.PAUSE_RESUME).decode("utf-8").rstrip("\n")
    assert decode_message(line) == CommandMessage(Command.PAUSE_RESUME)


def test_command_with_arg_round_trip() -> None:
    line = encode_command(Command.SET_INPUT_DEVICE, "AirPods Pro")
    decoded = decode_message(line.decode("utf-8").rstrip("\n"))
    assert decoded == CommandMessage(Command.SET_INPUT_DEVICE, "AirPods Pro")


def test_command_with_unsupported_arg_type_raises() -> None:
    with pytest.raises(ValueError):
        decode_message('{"type":"cmd","name":"set_input_device","arg":[1,2]}')


def test_devices_round_trip() -> None:
    devices = DeviceList(
        devices=(
            InputDeviceEntry(index=1, name="MacBook Pro Microphone", channels=1, sample_rate=48000.0),
            InputDeviceEntry(index=3, name="AirPods Pro", channels=1, sample_rate=24000.0),
        ),
        current_index=1,
    )
    line = encode_devices(devices).decode("utf-8").rstrip("\n")
    assert decode_message(line) == devices


def test_toggle_distill_command_round_trip() -> None:
    line = encode_command(Command.TOGGLE_DISTILL).decode("utf-8").rstrip("\n")
    assert decode_message(line) == CommandMessage(Command.TOGGLE_DISTILL)


def test_snapshot_carries_distill_state() -> None:
    snap = _snap(distill_enabled=True)
    line = encode_snapshot(snap).decode("utf-8").rstrip("\n")
    decoded = decode_message(line)
    assert isinstance(decoded, ControlSnapshot)
    assert decoded.distill_enabled is True
    assert decoded == snap


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
            drained: list[tuple[Command, object]] = []
            while time.monotonic() < deadline and not drained:
                drained = commands.drain()
                if not drained:
                    time.sleep(0.02)
            assert drained == [(Command.STOP, None)]
        finally:
            client.close()
    finally:
        server.stop()


def test_server_translates_command_arg_to_channel(short_tmp: Path) -> None:
    commands = CommandChannel()
    server = ControlServer(short_tmp / "control.sock", commands)
    server.start()
    try:
        client = _connect(server.socket_path)
        try:
            client.sendall(encode_command(Command.SET_INPUT_DEVICE, "AirPods Pro"))
            deadline = time.monotonic() + 1.0
            drained: list[tuple[Command, object]] = []
            while time.monotonic() < deadline and not drained:
                drained = commands.drain()
                if not drained:
                    time.sleep(0.02)
            assert drained == [(Command.SET_INPUT_DEVICE, "AirPods Pro")]
        finally:
            client.close()
    finally:
        server.stop()


def test_server_broadcasts_devices(short_tmp: Path) -> None:
    server = ControlServer(short_tmp / "control.sock", CommandChannel())
    server.start()
    try:
        client = _connect(server.socket_path)
        try:
            # Unlike snapshots, device lists are not replayed on accept, so
            # wait for the accept loop to register the client first.
            deadline = time.monotonic() + 1.0
            while server.connected_clients == 0 and time.monotonic() < deadline:
                time.sleep(0.02)
            devices = DeviceList(
                devices=(
                    InputDeviceEntry(index=0, name="Mic", channels=1, sample_rate=48000.0),
                ),
                current_index=0,
            )
            server.broadcast_devices(devices)
            line = _read_line(client)
            assert decode_message(line) == devices
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
