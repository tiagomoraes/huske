"""Tests for huske.models.RenderState."""

from __future__ import annotations

import threading

from huske.models import RenderState


def test_update_and_event_are_thread_safe() -> None:
    state = RenderState()
    errors: list[Exception] = []

    def bash() -> None:
        try:
            for i in range(500):
                state.update(current_chunk_seq=i)
                state.push_event("info", f"e{i}")
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=bash) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []
    assert state.current_chunk_seq < 500
    assert len(state.events) <= 5  # capped


def test_warnings_set_and_clear() -> None:
    state = RenderState()
    state.set_warning("k", "msg")
    assert state.warnings["k"] == "msg"
    state.clear_warning("k")
    assert "k" not in state.warnings


def test_event_deque_is_capped() -> None:
    state = RenderState()
    for i in range(20):
        state.push_event("info", f"e{i}")
    assert len(state.events) == 5
    assert state.events[-1].message == "e19"
