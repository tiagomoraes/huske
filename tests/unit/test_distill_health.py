"""Readiness probe shared by `huske doctor` and the live distillation toggle."""

from __future__ import annotations

import pytest

from huske.distill import client as client_mod
from huske.distill.health import probe_distill


def test_heuristic_backend_needs_no_daemon() -> None:
    r = probe_distill("heuristic")
    assert r.ok is True
    assert "no daemon" in r.detail
    assert r.hint is None


def test_model_present_is_ready(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        client_mod.OllamaClient,
        "list_models",
        lambda self: ["qwen3.5:0.8b", "llama3.2:3b"],
    )
    r = probe_distill("qwen3.5:0.8b", backend="ollama")
    assert r.ok is True
    assert "ready" in r.detail


def test_model_present_via_latest_tag(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        client_mod.OllamaClient, "list_models", lambda self: ["qwen3.5:0.8b:latest"]
    )
    r = probe_distill("qwen3.5:0.8b", backend="ollama")
    assert r.ok is True


def test_model_missing_gives_pull_hint(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(client_mod.OllamaClient, "list_models", lambda self: ["other:1b"])
    r = probe_distill("qwen3.5:0.8b", backend="ollama")
    assert r.ok is False
    assert "ollama pull qwen3.5:0.8b" in (r.hint or "")


def test_daemon_unreachable_is_not_ready(monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(self: object) -> list[str]:
        raise client_mod.DistillError("connection refused")

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", boom)
    r = probe_distill("qwen3.5:0.8b", backend="ollama", endpoint="http://127.0.0.1:11434")
    assert r.ok is False
    assert "unreachable" in r.detail
    assert "ollama serve" in (r.hint or "")
