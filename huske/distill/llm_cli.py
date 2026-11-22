"""``huske llm`` — set up and check transcript cleanup (LLM post-processing).

Built for Huske.app (every command has ``--json``; ADR 0006: the app shells
out instead of re-implementing provider logic) and equally usable by hand:

* ``status``      — where cleanup runs, whether it can right now, and why not;
* ``models``      — the models a provider offers (the app's model picker);
* ``key``         — API keys in the macOS Keychain (``set`` reads stdin);
* ``allow-cloud`` — record consent to send transcript text to one host;
* ``test``        — clean up a built-in synthetic sample end to end.

Nothing here prints or logs a key, and only ``test`` sends text to a model —
a synthetic sample, never a transcript.
"""

from __future__ import annotations

import getpass
import json
import sys
import time
from pathlib import Path
from typing import Any

from huske.config import RuntimeConfig, load_config, update_user_config
from huske.distill.client import DistillError
from huske.distill.providers import PROVIDERS, consent_granted, provider, resolve_target

_SAMPLES: dict[str, list[str]] = {
    "pt": [
        "bom dia pessoal hoje a gente vai revisar o deploy do cubernetes e os okrs do trimestre",
        "beleza eu mando o link do dash board no slack depois da reunião",
    ],
    "en": [
        "good morning everyone today we'll review the cube ernetes deploy and the okrs for "
        "the quarter",
        "sounds good i'll post the dash board link in slack after the meeting",
    ],
}

_MLX_MODELS = [
    "mlx-community/Qwen3.5-0.8B-4bit",
    "mlx-community/Qwen3.5-2B-4bit",
    "mlx-community/Qwen3.5-4B-4bit",
]


def _out(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _load(config_path: Path | None, backend: str | None = None) -> RuntimeConfig:
    cfg = load_config(config_path=config_path)
    if backend:
        provider(backend)  # validates
        cfg = cfg.model_copy(update={"distill_backend": backend})
    return cfg


def status_payload(cfg: RuntimeConfig) -> dict[str, Any]:
    """Everything the app's cleanup section shows, without sending any text."""
    from huske.distill import keychain
    from huske.distill.apple import probe_apple
    from huske.distill.health import probe_postprocess

    target = resolve_target(cfg)
    readiness = probe_postprocess(cfg)
    apple = probe_apple(cfg.language)
    return {
        "enabled": cfg.distill_enabled,
        "backend": target.name,
        "label": target.provider.label,
        "placement": target.provider.placement,
        "leaves_mac": target.leaves_mac,
        "host": target.host,
        "endpoint": target.endpoint,
        "model": target.model,
        "consent": consent_granted(target, cfg),
        "key_required": target.provider.needs_key,
        "key_accepted": target.provider.accepts_key,
        "key_present": keychain.has_key(target.name) if target.provider.accepts_key else False,
        "ready": readiness.ok,
        "reason": readiness.reason,
        "detail": readiness.detail,
        "hint": readiness.hint,
        "context_tokens": (
            min(target.context_tokens, apple.context_size)
            if target.name == "apple" and apple.available and not cfg.distill_context_tokens
            else target.context_tokens
        ),
        "keys": keychain.key_status(),
        "apple": {
            "available": apple.available,
            "reason": apple.reason,
            "detail": apple.detail,
            "hint": apple.hint,
            "context_size": apple.context_size or None,
            "helper": str(apple.helper) if apple.helper else None,
        },
        "providers": [
            {
                "name": p.name,
                "label": p.label,
                "placement": p.placement,
                "needs_key": p.needs_key,
                "default_model": p.default_model,
                "default_endpoint": p.default_endpoint,
            }
            for p in PROVIDERS.values()
        ],
    }


def run_status(*, json_output: bool, config_path: Path | None, backend: str | None) -> int:
    try:
        cfg = _load(config_path, backend)
    except ValueError as exc:
        _report_error(str(exc), json_output)
        return 2
    payload = status_payload(cfg)
    if json_output:
        _out(payload)
        return 0
    state = "on" if payload["enabled"] else "off"
    print(f"Transcript cleanup is {state}; runs on: {payload['label']}", flush=True)
    if payload["model"]:
        print(f"  model:    {payload['model']}", flush=True)
    if payload["endpoint"]:
        print(f"  endpoint: {payload['endpoint']}", flush=True)
    if payload["leaves_mac"]:
        allowed = "allowed" if payload["consent"] else "NOT allowed yet"
        print(f"  sends transcript text to {payload['host']} ({allowed})", flush=True)
    print(f"  {'ready' if payload['ready'] else 'not ready'}: {payload['detail']}", flush=True)
    if payload["hint"]:
        print(f"  hint: {payload['hint']}", flush=True)
    return 0


def list_models(cfg: RuntimeConfig) -> list[str]:
    """Model ids for ``cfg.distill_backend`` (may contact the provider)."""
    from huske.distill import keychain
    from huske.distill.http_llm import AnthropicBackend, OpenAICompatibleBackend

    target = resolve_target(cfg)
    if target.name == "mlx":
        return list(_MLX_MODELS)
    if target.name == "apple":
        return [target.model or ""]
    if target.name == "ollama":
        from huske.distill.client import OllamaClient

        return OllamaClient(target.endpoint or "", timeout=10.0).list_models()
    key = keychain.get_key(target.name) if target.provider.accepts_key else None
    if target.provider.needs_key and not key:
        raise DistillError(
            f"add an API key for {target.provider.label} first "
            f"(`huske llm key set {target.name}`)",
            kind="auth",
        )
    # Listing models sends the key, never transcript text, so it needs no
    # transcript consent — it is the explicit step before choosing one.
    if target.name == "anthropic":
        return AnthropicBackend(target, consented=True, api_key=key, timeout=15.0).list_models()
    models = OpenAICompatibleBackend(target, consented=True, api_key=key, timeout=15.0).list_models()
    return sorted(models) if target.provider.placement == "cloud" else models


def run_models(*, json_output: bool, config_path: Path | None, backend: str | None) -> int:
    try:
        cfg = _load(config_path, backend)
        models = list_models(cfg)
    except (ValueError, DistillError) as exc:
        _report_error(str(exc), json_output, models=[])
        return 1
    if json_output:
        _out({"backend": cfg.distill_backend, "models": models, "error": None})
    else:
        for model in models:
            print(model, flush=True)
    return 0


def _report_error(message: str, json_output: bool, **extra: Any) -> None:
    if json_output:
        _out({"error": message, **extra})
    else:
        print(f"[error] {message}", file=sys.stderr, flush=True)


def run_key_set(provider_name: str, *, json_output: bool) -> int:
    from huske.distill import keychain

    prov = PROVIDERS.get(provider_name)
    if prov is None or not prov.accepts_key:
        names = ", ".join(n for n, p in PROVIDERS.items() if p.accepts_key)
        _report_error(f"{provider_name!r} takes no API key (one of: {names})", json_output,
                      saved=False)
        return 2
    if sys.stdin.isatty():
        secret = getpass.getpass(f"{prov.label} API key: ")
    else:
        secret = sys.stdin.readline()
    try:
        keychain.set_key(provider_name, secret)
    except keychain.KeychainError as exc:
        _report_error(str(exc), json_output, saved=False)
        return 2
    if json_output:
        _out({"provider": provider_name, "saved": True, "error": None})
    else:
        print(f"saved the {PROVIDERS[provider_name].label} API key in your Keychain", flush=True)
    return 0


def run_key_remove(provider_name: str, *, json_output: bool) -> int:
    from huske.distill import keychain

    try:
        existed = keychain.delete_key(provider_name)
    except keychain.KeychainError as exc:
        _report_error(str(exc), json_output, removed=False)
        return 2
    if json_output:
        _out({"provider": provider_name, "removed": existed, "error": None})
    else:
        print("removed" if existed else "there was no key to remove", flush=True)
    return 0


def run_key_list(*, json_output: bool) -> int:
    from huske.distill import keychain

    status = keychain.key_status()
    if json_output:
        _out({"keys": status})
    else:
        for name, present in status.items():
            print(f"{name:18} {'saved' if present else '—'}", flush=True)
    return 0


def run_allow_cloud(
    *, yes: bool, revoke: bool, json_output: bool, config_path: Path | None
) -> int:
    try:
        cfg = load_config(config_path=config_path)
    except ValueError as exc:
        _report_error(str(exc), json_output)
        return 2
    if revoke:
        update_user_config({"distill_cloud_consent": None}, config_path=config_path)
        if json_output:
            _out({"consent": None, "error": None})
        else:
            print("Huske will no longer send transcripts off this Mac.", flush=True)
        return 0
    target = resolve_target(cfg)
    if not target.leaves_mac or not target.host:
        message = f"{target.provider.label} runs on this Mac; nothing to allow."
        if json_output:
            _out({"consent": cfg.distill_cloud_consent, "error": None, "note": message})
        else:
            print(message, flush=True)
        return 0
    warning = (
        f"Transcript cleanup with {target.provider.label} sends the text of every transcript "
        f"to {target.host}. It leaves this Mac and is handled under that provider's terms. "
        "Raw audio is never sent."
    )
    if not yes:
        if json_output or not sys.stdin.isatty():
            _report_error("pass --yes to confirm sending transcripts off this Mac", json_output)
            return 2
        print(warning, flush=True)
        answer = input(f"Allow sending transcripts to {target.host}? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Nothing changed.", flush=True)
            return 1
    update_user_config({"distill_cloud_consent": target.host}, config_path=config_path)
    if json_output:
        _out({"consent": target.host, "error": None})
    else:
        print(f"Allowed: transcripts may be sent to {target.host}.", flush=True)
    return 0


def run_test(*, json_output: bool, config_path: Path | None) -> int:
    """Clean up a synthetic sample with the configured backend."""
    from huske.distill.distiller import build_distiller

    try:
        cfg = load_config(config_path=config_path)
    except ValueError as exc:
        _report_error(str(exc), json_output, ok=False)
        return 2
    sample = _SAMPLES.get(cfg.language or "", _SAMPLES["en"])
    started = time.monotonic()
    corrector = None
    try:
        corrector = build_distiller(cfg)
        result = corrector.correct_runs(sample, language=cfg.language)
    except DistillError as exc:
        _report_error(str(exc), json_output, ok=False, kind=exc.kind)
        return 1
    finally:
        if corrector is not None:
            corrector.close()
    seconds = round(time.monotonic() - started, 2)
    payload = {
        "ok": True,
        "label": corrector.label,
        "input": sample,
        "output": result.texts,
        "changed": result.changed,
        "kept_raw": result.kept_raw,
        "seconds": seconds,
        "error": None,
    }
    if json_output:
        _out(payload)
    else:
        print(f"{corrector.label} ({seconds}s):", flush=True)
        for before, after in zip(sample, result.texts, strict=True):
            print(f"  - {before}\n  + {after}", flush=True)
    return 0


def run_languages(*, json_output: bool) -> int:
    from huske.languages import WHISPER_LANGUAGES, engine_support

    rows = [
        {
            "code": code,
            "name": name.title(),
            "whisper": engine_support("whisper", code),
            "parakeet": engine_support("parakeet", code),
        }
        for code, name in WHISPER_LANGUAGES.items()
    ]
    if json_output:
        _out({"languages": rows})
        return 0
    print("code  language               whisper  parakeet", flush=True)
    for row in rows:
        print(f"{row['code']:5} {row['name']:22} {row['whisper']:8} {row['parakeet']}", flush=True)
    print(
        "\nwhisper: the language is pinned. parakeet: detected from the audio — "
        "`language` only guards against windows that drift into English.",
        flush=True,
    )
    return 0
