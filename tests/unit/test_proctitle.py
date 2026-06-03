"""Unit tests for the best-effort process-title helper.

The title is cosmetic, so the helper must never raise — whether the optional
``setproctitle`` dependency is absent or its platform call fails.
"""

from __future__ import annotations

import sys
import types

from huske.proctitle import set_process_title


def test_set_process_title_calls_setproctitle(monkeypatch):
    calls: list[str] = []
    fake = types.ModuleType("setproctitle")
    fake.setproctitle = calls.append  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "setproctitle", fake)

    assert set_process_title("huske") is True
    assert calls == ["huske"]


def test_set_process_title_missing_dependency_is_noop(monkeypatch):
    # A ``None`` entry makes ``from setproctitle import ...`` raise ImportError,
    # simulating the package not being installed.
    monkeypatch.setitem(sys.modules, "setproctitle", None)

    assert set_process_title("huske") is False


def test_set_process_title_swallows_runtime_error(monkeypatch):
    def boom(_title: str) -> None:
        raise RuntimeError("LaunchServices unavailable")

    fake = types.ModuleType("setproctitle")
    fake.setproctitle = boom  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "setproctitle", fake)

    assert set_process_title("huske") is False
