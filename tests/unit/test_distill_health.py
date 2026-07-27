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


def test_reason_codes_drive_auto_management(monkeypatch: pytest.MonkeyPatch) -> None:
    """Only the Ollama codes are actionable, so they are what auto-manage branches on.

    `backend="ollama"` is explicit: the default flipped to `mlx` in 0.11.0, and
    without it these assertions would silently probe the built-in backend and
    never reach the monkeypatched daemon at all.
    """
    assert probe_distill("heuristic").reason == "no_daemon"

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", lambda self: ["qwen3.5:0.8b"])
    assert probe_distill("qwen3.5:0.8b", backend="ollama").reason == "ready"

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", lambda self: ["other:1b"])
    assert probe_distill("qwen3.5:0.8b", backend="ollama").reason == "model_missing"

    def boom(self: object) -> list[str]:
        raise client_mod.DistillError("connection refused")

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", boom)
    assert probe_distill("qwen3.5:0.8b", backend="ollama").reason == "unreachable"


def test_mlx_backend_reason_codes(monkeypatch: pytest.MonkeyPatch) -> None:
    """The built-in backend reports its own codes, never a daemon one.

    A missing mlx-lm is a broken install; auto-management must not mistake it
    for a daemon it can start.
    """
    import huske.distill.mlx_backend as mlx_mod

    monkeypatch.setattr(mlx_mod, "mlx_runtime_available", lambda: False)
    missing = probe_distill("qwen3.5:0.8b", backend="mlx")
    assert missing.ok is False
    assert missing.reason == "no_runtime"

    monkeypatch.setattr(mlx_mod, "mlx_runtime_available", lambda: True)
    monkeypatch.setattr(mlx_mod, "model_is_cached", lambda repo: True)
    assert probe_distill("qwen3.5:0.8b", backend="mlx").reason == "ready"

    # Not cached is still ready — the model downloads on first use.
    monkeypatch.setattr(mlx_mod, "model_is_cached", lambda repo: False)
    uncached = probe_distill("qwen3.5:0.8b", backend="mlx")
    assert uncached.ok is True
    assert uncached.reason == "ready"
