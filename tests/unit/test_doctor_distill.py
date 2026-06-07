"""`huske doctor` distillation check: off (opt-in), ready, missing model, daemon down."""

from __future__ import annotations

import pytest

from huske.config import RuntimeConfig
from huske.distill import client as client_mod
from huske.doctor import _distill_checks


def test_off_is_informational_ok() -> None:
    checks = _distill_checks(RuntimeConfig(distill_enabled=False))
    assert len(checks) == 1
    assert checks[0].ok is True
    assert "off" in checks[0].detail


def test_heuristic_backend_needs_no_daemon() -> None:
    cfg = RuntimeConfig(distill_enabled=True, distill_model="heuristic")
    checks = _distill_checks(cfg)
    assert checks[0].ok is True
    assert "no daemon" in checks[0].detail


def test_model_present_is_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        client_mod.OllamaClient, "list_models", lambda self: ["gemma4:e2b", "qwen3:4b"]
    )
    cfg = RuntimeConfig(distill_enabled=True, distill_model="gemma4:e2b")
    checks = _distill_checks(cfg)
    assert checks[0].ok is True
    assert "ready" in checks[0].detail


def test_model_missing_fails_with_pull_hint(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(client_mod.OllamaClient, "list_models", lambda self: ["other:1b"])
    cfg = RuntimeConfig(distill_enabled=True, distill_model="gemma4:e2b")
    checks = _distill_checks(cfg)
    assert checks[0].ok is False
    assert "ollama pull gemma4:e2b" in (checks[0].hint or "")


def test_daemon_unreachable_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(self: object) -> list[str]:
        raise client_mod.DistillError("connection refused")

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", boom)
    cfg = RuntimeConfig(distill_enabled=True, distill_model="gemma4:e2b")
    checks = _distill_checks(cfg)
    assert checks[0].ok is False
    assert "unreachable" in checks[0].detail
