"""Tests for the built-in MLX distillation backend (huske/distill/mlx_backend.py).

The real model never loads here: fake mode (HUSKE_DISTILL_MLX_FAKE) exercises
the subprocess pipe protocol, and the routing/resolution logic is pure.
"""

from __future__ import annotations

import pytest

from huske.config import RuntimeConfig
from huske.distill import health as health_mod
from huske.distill.distiller import HeuristicDistiller, build_backend
from huske.distill.mlx_backend import (
    DEFAULT_MLX_MODEL,
    MLXDistiller,
    _clean_reply,
    resolve_mlx_model,
)
from huske.distill.ollama_backend import OllamaBackend

# ---------------------------------------------------------------------------
# model resolution
# ---------------------------------------------------------------------------


def test_hf_repos_pass_through() -> None:
    assert resolve_mlx_model("mlx-community/Qwen3.5-2B-4bit") == "mlx-community/Qwen3.5-2B-4bit"


def test_known_ollama_tags_map_to_mlx_builds() -> None:
    assert resolve_mlx_model("qwen3.5:0.8b") == DEFAULT_MLX_MODEL
    assert resolve_mlx_model("qwen3.5:0.8b-mlx") == "mlx-community/Qwen3.5-0.8B-4bit"
    assert resolve_mlx_model("qwen3.5:4b") == "mlx-community/Qwen3.5-4B-4bit"
    assert resolve_mlx_model("QWEN3.5:2B") == "mlx-community/Qwen3.5-2B-4bit"


def test_unknown_tag_passes_through_unchanged() -> None:
    assert resolve_mlx_model("somemodel:7b") == "somemodel:7b"


# ---------------------------------------------------------------------------
# reply cleaning
# ---------------------------------------------------------------------------


def test_clean_reply_strips_think_blocks() -> None:
    raw = "<think>reasoning...</think>\n[1] Olá."
    assert _clean_reply(raw) == "[1] Olá."


def test_clean_reply_strips_chat_control_tokens() -> None:
    assert _clean_reply("[1] Valeu, pessoal!<|im_end|>") == "[1] Valeu, pessoal!"
    assert _clean_reply("[1] ok<|endoftext|>") == "[1] ok"


# ---------------------------------------------------------------------------
# builder routing
# ---------------------------------------------------------------------------


def test_build_backend_defaults_to_builtin_mlx() -> None:
    d = build_backend(RuntimeConfig())
    try:
        assert isinstance(d, MLXDistiller)
        assert d.provider == "mlx"
        assert d.model_id == "mlx-community/Qwen3.5-0.8B-4bit"
    finally:
        d.close()  # no process was started; must be a no-op


def test_build_backend_ollama_backend_still_available() -> None:
    d = build_backend(RuntimeConfig(distill_backend="ollama"))
    assert isinstance(d, OllamaBackend)
    assert d.model_id == "qwen3.5:0.8b"


def test_build_backend_heuristic_ignores_backend() -> None:
    assert isinstance(build_backend(RuntimeConfig(distill_model="heuristic")), HeuristicDistiller)
    assert isinstance(
        build_backend(RuntimeConfig(distill_model="heuristic", distill_backend="ollama")),
        HeuristicDistiller,
    )


# ---------------------------------------------------------------------------
# subprocess protocol (fake mode — no weights)
# ---------------------------------------------------------------------------


def test_fake_mode_round_trip(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_DISTILL_MLX_FAKE", "1")
    d = MLXDistiller("mlx-community/whatever", timeout=30.0)
    try:
        prompt = "<transcript>\n[1] Some passage.\n</transcript>"
        assert d.complete("rules", prompt, max_tokens=64) == "[1] Some passage."
        # Second call reuses the live subprocess.
        pid = d.pid
        assert d.complete("rules", "[1] Another.", max_tokens=64) == "[1] Another."
        assert d.pid == pid
    finally:
        d.close()


def test_close_is_idempotent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_DISTILL_MLX_FAKE", "1")
    d = MLXDistiller("mlx-community/whatever", timeout=30.0)
    d.complete("rules", "[1] x", max_tokens=16)
    d.close()
    d.close()


# ---------------------------------------------------------------------------
# readiness probe
# ---------------------------------------------------------------------------


def test_probe_mlx_ready_when_runtime_available(monkeypatch: pytest.MonkeyPatch) -> None:
    import huske.distill.mlx_backend as mlx_mod

    monkeypatch.setattr(mlx_mod, "mlx_runtime_available", lambda: True)
    monkeypatch.setattr(mlx_mod, "model_is_cached", lambda repo: False)
    r = health_mod.probe_distill("qwen3.5:0.8b", backend="mlx")
    assert r.ok is True
    assert "downloads on first use" in r.detail
    assert DEFAULT_MLX_MODEL in r.detail


def test_probe_mlx_reports_cached_model(monkeypatch: pytest.MonkeyPatch) -> None:
    import huske.distill.mlx_backend as mlx_mod

    monkeypatch.setattr(mlx_mod, "mlx_runtime_available", lambda: True)
    monkeypatch.setattr(mlx_mod, "model_is_cached", lambda repo: True)
    r = health_mod.probe_distill(DEFAULT_MLX_MODEL, backend="mlx")
    assert r.ok is True
    assert "cached" in r.detail


def test_probe_mlx_not_ready_without_runtime(monkeypatch: pytest.MonkeyPatch) -> None:
    import huske.distill.mlx_backend as mlx_mod

    monkeypatch.setattr(mlx_mod, "mlx_runtime_available", lambda: False)
    r = health_mod.probe_distill(DEFAULT_MLX_MODEL, backend="mlx")
    assert r.ok is False
    assert "mlx-lm" in r.detail


def test_probe_ollama_backend_unchanged(monkeypatch: pytest.MonkeyPatch) -> None:
    from huske.distill import client as client_mod

    def boom(self: object) -> list[str]:
        raise client_mod.DistillError("connection refused")

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", boom)
    r = health_mod.probe_distill("qwen3.5:0.8b", backend="ollama")
    assert r.ok is False
    assert "unreachable" in r.detail


# ---------------------------------------------------------------------------
# worker releases the LLM subprocess
# ---------------------------------------------------------------------------


def test_worker_stop_closes_distiller(tmp_path) -> None:  # type: ignore[no-untyped-def]
    from huske.distill.worker import DistillWorker

    class ClosableDistiller(HeuristicDistiller):
        closed = False

        def close(self) -> None:
            self.closed = True

    distiller = ClosableDistiller()
    worker = DistillWorker(tmp_path, distiller)  # a bare backend is accepted
    worker.start()
    worker.stop(drain_timeout=5.0)
    assert distiller.closed is True
