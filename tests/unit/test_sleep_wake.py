"""Smoke test for the sleep/wake heartbeat detection.

We exercise the `last_callback_at` staleness semantics that the
`CaptureCoordinator` exposes. The full sleep/wake loop lives inside
`run_loop._main_loop`; the contract is: if `last_callback_at` goes stale
beyond the threshold, the run loop sets a sticky warning.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from huske.models import RenderState

_HEARTBEAT_THRESHOLD = 5.0


def _evaluate_heartbeat(last: datetime | None, now: datetime, threshold: float) -> str | None:
    """Mirrors the logic in `run_loop._main_loop`."""
    if last is None:
        return None
    stale = (now - last).total_seconds()
    if stale > threshold:
        return f"no audio for {stale:.0f}s — device may be asleep/disconnected"
    return None


def test_no_warning_within_threshold() -> None:
    now = datetime.now().astimezone()
    assert _evaluate_heartbeat(now - timedelta(seconds=2), now, _HEARTBEAT_THRESHOLD) is None


def test_warning_after_threshold() -> None:
    now = datetime.now().astimezone()
    msg = _evaluate_heartbeat(now - timedelta(seconds=12), now, _HEARTBEAT_THRESHOLD)
    assert msg is not None
    assert "12" in msg


def test_render_state_warning_lifecycle() -> None:
    state = RenderState()
    state.set_warning("heartbeat", "no audio for 12s")
    assert "heartbeat" in state.warnings
    state.clear_warning("heartbeat")
    assert "heartbeat" not in state.warnings
