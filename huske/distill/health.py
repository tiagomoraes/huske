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
    ``"ready"``, ``"no_daemon"`` (heuristic backend), ``"no_runtime"`` (the
    built-in mlx backend's runtime is missing), ``"unreachable"`` (daemon down),
    or ``"model_missing"`` (daemon up, model not pulled).

    Only ``"unreachable"`` and ``"model_missing"`` are actionable by
    auto-management, and only on the Ollama backend — see
    ``huske.distill.ollama_manage.ensure_ready``.
    """

    ok: bool
    detail: str
    hint: str | None = None
    reason: str = ""


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
        return Readiness(True, f"backend '{model}' (no daemon needed)", reason="no_daemon")

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
                # Its own code: auto-management only ever drives Ollama, and a
                # missing mlx-lm is a broken install, not a daemon to start.
                reason="no_runtime",
            )
        repo = resolve_mlx_model(model)
        if model_is_cached(repo):
            return Readiness(True, f"built-in model '{repo}' cached and ready", reason="ready")
        return Readiness(
            True,
            f"built-in model '{repo}' ready (downloads on first use, ~0.6 GB)",
            reason="ready",
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


def probe_postprocess(cfg: object, *, timeout: float = 5.0) -> Readiness:
    """Readiness of the configured post-processing target, for any backend.

    Never sends transcript text, and never contacts a cloud provider (a doctor
    run must not leak an API key's use or cost money): for cloud targets it
    checks the key, the consent and the model locally. ``huske llm test``
    is the explicit end-to-end check.
    """
    from huske.distill.providers import consent_granted, resolve_target

    model = getattr(cfg, "distill_model", None)
    if model in ("heuristic", "fake"):
        return Readiness(True, f"backend '{model}' (no daemon needed)", reason="no_daemon")
    target = resolve_target(cfg)
    label = target.provider.label
    if target.name in ("mlx", "ollama"):
        return probe_distill(
            target.model or "", backend=target.name, endpoint=target.endpoint or "", timeout=timeout
        )
    if target.name == "apple":
        from huske.distill.apple import probe_apple

        status = probe_apple(getattr(cfg, "language", None))
        if status.available:
            detail = f"Apple Intelligence is ready ({status.context_size:,}-token context)"
            if status.locale_supported is False:
                return Readiness(
                    False,
                    "Apple Intelligence doesn't support this transcript language",
                    "Choose another way to clean up transcripts, or change `language`.",
                    reason="unsupported_language",
                )
            return Readiness(True, detail, reason="ready")
        return Readiness(False, status.detail, status.hint, reason=status.reason or "unknown")
    if target.provider.needs_key:
        from huske.distill import keychain

        if not keychain.has_key(target.name):
            return Readiness(
                False,
                f"no {label} API key in the Keychain",
                f"Add it in Huske.app → Configuration, or run `huske llm key set {target.name}`.",
                reason="needs_key",
            )
    if not consent_granted(target, cfg):
        return Readiness(
            False,
            f"sending transcripts to {target.host} hasn't been allowed",
            "Allow it in Huske.app → Configuration, or run `huske llm allow-cloud`.",
            reason="needs_consent",
        )
    if target.provider.placement == "cloud":
        if not target.model:
            return Readiness(
                False,
                f"no {label} model chosen",
                "Pick one in Huske.app, or `huske llm models` then "
                "`huske config set distill_model <id>`.",
                reason="needs_model",
            )
        return Readiness(True, f"{label}: {target.model} (sends transcripts to {target.host})",
                         reason="ready")
    # openai_compatible: a reachable server with a model.
    from huske.distill.client import DistillError
    from huske.distill.http_llm import OpenAICompatibleBackend

    key = None
    if target.provider.accepts_key:
        from huske.distill import keychain

        key = keychain.get_key(target.name)
    backend = OpenAICompatibleBackend(target, consented=True, api_key=key, timeout=timeout)
    try:
        models = backend.list_models()
    except DistillError as exc:
        return Readiness(
            False,
            f"{label} at {target.endpoint} is not answering: {exc}",
            "Start the server (LM Studio: Developer → Start server) or fix distill_endpoint.",
            reason="unreachable",
        )
    if target.model and models and target.model not in models:
        return Readiness(
            False,
            f"model '{target.model}' isn't loaded on {target.endpoint} "
            f"(have: {', '.join(models[:5]) or 'none'})",
            "Load it in the server, or pick one of the listed models.",
            reason="model_missing",
        )
    if not target.model and not models:
        return Readiness(False, f"{label} lists no models", "Load a model in the server.",
                         reason="model_missing")
    chosen = target.model or models[0]
    return Readiness(True, f"{label}: {chosen} at {target.endpoint}", reason="ready")
