"""Readiness probe for the optional LLM-distillation subsystem.

One shared check answers "can we distill right now?" — used by ``huske doctor``
(diagnostics) and by the live toggle in ``huske run`` (so flipping distillation
on gives immediate, actionable feedback instead of waiting for the next chunk).

It mirrors the daemon/model logic that lived in ``huske.doctor`` so both callers
stay in lockstep. The ``heuristic``/``fake`` backends need no daemon, so they are
always "ready". Everything else probes the local LLM daemon's model list.

Like the rest of ``huske.distill``, the daemon client is imported lazily so the
base recording pipeline never pulls this path in eagerly.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Readiness:
    """Whether distillation can run, with a human-readable detail + fix-it hint."""

    ok: bool
    detail: str
    hint: str | None = None


def probe_distill(
    model: str,
    *,
    backend: str = "mlx",
    endpoint: str = "http://127.0.0.1:11434",
    timeout: float = 5.0,
) -> Readiness:
    """Probe whether ``model`` is servable now.

    ``heuristic``/``fake`` need nothing. The built-in ``mlx`` backend is ready
    whenever its runtime is importable — the model downloads on first use, so
    a fresh install must not fail the probe. The ``ollama`` backend enumerates
    the daemon's pulled models: an unreachable daemon or an un-pulled model is
    "not ready" with a hint.
    """
    if model in ("heuristic", "fake"):
        return Readiness(True, f"backend '{model}' (no daemon needed)")

    if backend == "mlx":
        from huske.distill.mlx_backend import (
            mlx_runtime_available,
            model_is_cached,
            resolve_mlx_model,
        )

        if not mlx_runtime_available():
            return Readiness(
                False,
                "built-in LLM runtime (mlx-lm) is not installed",
                "Reinstall/upgrade huske — mlx-lm ships with the base install "
                "on Apple Silicon (pip install -U huske).",
            )
        repo = resolve_mlx_model(model)
        if model_is_cached(repo):
            return Readiness(True, f"built-in model '{repo}' cached and ready")
        return Readiness(
            True, f"built-in model '{repo}' ready (downloads on first use, ~0.6 GB)"
        )

    from huske.distill.client import DistillError, OllamaClient

    client = OllamaClient(endpoint, timeout=timeout)
    try:
        models = client.list_models()
    except DistillError as exc:
        # The client's connection error already names the endpoint ("could
        # not reach LLM daemon at <base>: …") — don't stack a second copy of
        # the same phrase in front of it.
        detail = str(exc)
        if "LLM daemon" not in detail:
            detail = f"LLM daemon unreachable at {endpoint}: {detail}"
        return Readiness(
            False,
            detail,
            "Start it (e.g. `ollama serve` or open the Ollama app) or fix distill_endpoint.",
        )

    present = (
        model in models
        or f"{model}:latest" in models
        or any(m.split(":", 1)[0] == model.split(":", 1)[0] and model in m for m in models)
    )
    if present:
        return Readiness(True, f"{backend}: model '{model}' ready ({len(models)} pulled)")
    return Readiness(
        False,
        f"model '{model}' not pulled (have: {', '.join(models) or 'none'})",
        f"Run `ollama pull {model}`.",
    )
