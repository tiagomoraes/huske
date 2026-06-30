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
    """Whether distillation can run, with a human-readable detail + fix-it hint.

    ``reason`` is a stable machine code for branching (e.g. auto-management):
    ``"ready"``, ``"no_daemon"`` (heuristic backend), ``"unreachable"`` (daemon
    down), or ``"model_missing"`` (daemon up, model not pulled).
    """

    ok: bool
    detail: str
    hint: str | None = None
    reason: str = ""


def probe_distill(
    model: str,
    *,
    backend: str = "ollama",
    endpoint: str = "http://127.0.0.1:11434",
    timeout: float = 5.0,
) -> Readiness:
    """Probe whether ``model`` is servable now.

    ``heuristic``/``fake`` need no daemon. Otherwise we enumerate the daemon's
    pulled models: an unreachable daemon or an un-pulled model is "not ready"
    with a hint, a matching tag is "ready".
    """
    if model in ("heuristic", "fake"):
        return Readiness(True, f"backend '{model}' (no daemon needed)", reason="no_daemon")

    from huske.distill.client import DistillError, OllamaClient

    client = OllamaClient(endpoint, timeout=timeout)
    try:
        models = client.list_models()
    except DistillError as exc:
        return Readiness(
            False,
            f"LLM daemon unreachable at {endpoint}: {exc}",
            "Start it (e.g. `ollama serve`) or fix distill_endpoint.",
            reason="unreachable",
        )

    present = (
        model in models
        or f"{model}:latest" in models
        or any(m.split(":", 1)[0] == model.split(":", 1)[0] and model in m for m in models)
    )
    if present:
        return Readiness(
            True, f"{backend}: model '{model}' ready ({len(models)} pulled)", reason="ready"
        )
    return Readiness(
        False,
        f"model '{model}' not pulled (have: {', '.join(models) or 'none'})",
        f"Run `ollama pull {model}`.",
        reason="model_missing",
    )
