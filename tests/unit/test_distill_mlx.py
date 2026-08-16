"""Tests for the built-in MLX distillation backend (huske/distill/mlx_backend.py).

The real model never loads here: fake mode (HUSKE_DISTILL_MLX_FAKE) exercises
the subprocess pipe protocol, and the routing/resolution logic is pure.
"""

from __future__ import annotations

import pytest

from huske.distill import health as health_mod
from huske.distill.distiller import HeuristicDistiller, OllamaDistiller, build_distiller
from huske.distill.mlx_backend import (
    DEFAULT_MLX_MODEL,
    MLXDistiller,
    _clean_reply,
    resolve_mlx_model,
)

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


def test_clean_reply_strips_think_blocks_and_fences() -> None:
    raw = '<think>reasoning...</think>\n```json\n{"text": "a"}\n```'
    assert _clean_reply(raw) == '{"text": "a"}'


def test_clean_reply_isolates_json_amid_prose() -> None:
    raw = 'Sure! Here you go: {"text": "a"} Hope that helps.'
    assert _clean_reply(raw) == '{"text": "a"}'


# ---------------------------------------------------------------------------
# builder routing
# ---------------------------------------------------------------------------


def test_build_distiller_defaults_to_builtin_mlx() -> None:
    d = build_distiller("mlx-community/Qwen3.5-0.8B-4bit")
    try:
        assert isinstance(d, MLXDistiller)
        assert d.backend == "mlx"
    finally:
        d.close()  # no process was started; must be a no-op


def test_build_distiller_ollama_backend_still_available() -> None:
    d = build_distiller("qwen3.5:0.8b", backend="ollama")
    assert isinstance(d, OllamaDistiller)
    assert d.backend == "ollama"


def test_build_distiller_heuristic_ignores_backend() -> None:
    assert isinstance(build_distiller("heuristic"), HeuristicDistiller)
    assert isinstance(build_distiller("heuristic", backend="ollama"), HeuristicDistiller)


# ---------------------------------------------------------------------------
# subprocess protocol (fake mode — no weights)
# ---------------------------------------------------------------------------


def test_fake_mode_round_trip(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_DISTILL_MLX_FAKE", "1")
    d = MLXDistiller("mlx-community/whatever", max_statements=4, timeout=30.0)
    try:
        statements = d.distill_passage("Some passage.", sources=["mic"], language="en")
        assert statements == ["fake statement"]
        # Second call reuses the live subprocess.
        assert d.distill_passage("Another.", sources=["mic"], language="en") == [
            "fake statement"
        ]
    finally:
        d.close()


def test_close_is_idempotent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HUSKE_DISTILL_MLX_FAKE", "1")
    d = MLXDistiller("mlx-community/whatever", timeout=30.0)
    d.distill_passage("x", sources=["mic"], language="en")
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
    worker = DistillWorker(tmp_path, distiller)
    worker.start()
    worker.stop(drain_timeout=5.0)
    assert distiller.closed is True
