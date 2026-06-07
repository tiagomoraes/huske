"""Shared unit-test fixtures."""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _no_process_renice(monkeypatch: pytest.MonkeyPatch) -> None:
    """`huske index` runs low-impact by default, which lowers the *process* CPU
    priority via ``os.nice``. The unit suite drives the command in-process
    (CliRunner), so neutralize the renice — otherwise pytest would progressively
    slow itself down over the run. Tests that assert the throttle fired re-patch
    this same seam with their own spy.
    """
    try:
        import huske.search.runner as runner
    except Exception:
        pass
    else:
        monkeypatch.setattr(runner, "_lower_process_priority", lambda *a, **k: None)

    # `huske distill` throttles the same way; neutralize it too.
    try:
        import huske.distill.runner as distill_runner
    except Exception:
        return
    monkeypatch.setattr(distill_runner, "_lower_process_priority", lambda *a, **k: None)
