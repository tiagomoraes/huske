"""Tests for the v2 control-plane snapshot the native macOS app consumes."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from huske import __version__
from huske.ipc.protocol import decode_message, encode_snapshot
from huske.models import RenderState
from huske.run_loop import build_control_snapshot


def _state(**overrides: object) -> RenderState:
    state = RenderState(session_id="20260721T090000_abcd")
    state.update(**overrides)
    return state


def test_snapshot_carries_render_state_fields() -> None:
    started = datetime(2026, 7, 21, 9, 0, 0).astimezone()
    chunk_started = datetime(2026, 7, 21, 9, 5, 0).astimezone()
    state = _state(
        recording=True,
        current_chunk_seq=4,
        queue_depth=2,
        peak_levels=(-21.44, -33.81),
        chunk_started_at=chunk_started,
        last_saved=Path("/tmp/out/2026-07-21/090500_abcd0000_003.md"),
        screenshots_count=7,
        screenshots_enabled=True,
    )
    state.set_warning("heartbeat", "no audio for 6s")
    state.push_event("info", "chunk 004 queued for transcription")

    snap = build_control_snapshot(
        state,
        session_id="20260721T090000_abcd",
        session_started_at=started,
        output_root=Path("/tmp/out"),
        input_device_name="MacBook Pro Microphone",
    )

    assert snap.recording is True
    assert snap.current_chunk_seq == 4
    assert snap.queue_depth == 2
    assert snap.peak_mic_db == -21.4  # rounded to 0.1 dB
    assert snap.peak_system_db == -33.8
    assert snap.chunk_started_at == chunk_started.isoformat()
    assert snap.session_started_at == started.isoformat()
    assert snap.huske_version == __version__
    assert snap.output_root == "/tmp/out"
    assert snap.last_saved_name == "090500_abcd0000_003.md"
    assert snap.last_saved_path == "/tmp/out/2026-07-21/090500_abcd0000_003.md"
    assert snap.screenshots_count == 7
    assert snap.input_device_name == "MacBook Pro Microphone"
    assert snap.warnings == {"heartbeat": "no audio for 6s"}
    assert len(snap.events) == 1
    assert snap.events[0]["severity"] == "info"
    assert "ts" in snap.events[0]


def test_snapshot_round_trips_over_the_wire() -> None:
    state = _state(recording=True, peak_levels=(-30.0, -45.0))
    state.push_event("warn", "distillation unavailable")
    snap = build_control_snapshot(
        state,
        session_id="s",
        session_started_at=datetime(2026, 7, 21, 9, 0, 0).astimezone(),
        output_root=Path("/tmp/out"),
        input_device_name=None,
    )
    line = encode_snapshot(snap).decode("utf-8").rstrip("\n")
    assert decode_message(line) == snap


def test_snapshot_defaults_when_nothing_recorded_yet() -> None:
    snap = build_control_snapshot(
        _state(),
        session_id="s",
        session_started_at=datetime(2026, 7, 21, 9, 0, 0).astimezone(),
        output_root=Path("/tmp/out"),
        input_device_name=None,
    )
    assert snap.recording is False
    assert snap.chunk_started_at is None
    assert snap.last_saved_name is None
    assert snap.events == []
    assert snap.warnings == {}
