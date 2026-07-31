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
