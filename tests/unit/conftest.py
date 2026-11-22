"""Shared unit-test fixtures."""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _no_process_renice(monkeypatch: pytest.MonkeyPatch) -> None:
    """Neutralize ``huske distill`` process renicing in in-process CLI tests."""
    try:
        import huske.distill.runner as distill_runner
    except Exception:
        return
    monkeypatch.setattr(distill_runner, "_lower_process_priority", lambda *a, **k: None)


@pytest.fixture(autouse=True)
def _no_real_synced_capture(monkeypatch: pytest.MonkeyPatch) -> None:
    """Never build a real Core Audio aggregate in unit tests.

    Real construction touches the HAL and can block on a privacy prompt. Tests
    that exercise synced capture patch ``open_synced_capture`` themselves.
    """
    try:
        import huske.capture.coordinator as coordinator
        from huske.capture.synced_capture import SyncedCaptureError
    except Exception:
        return

    def _unavailable(*_a: object, **_k: object) -> object:
        raise SyncedCaptureError("synced capture disabled in unit tests")

    monkeypatch.setattr(coordinator, "open_synced_capture", _unavailable)
