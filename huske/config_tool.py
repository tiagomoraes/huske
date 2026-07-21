"""`huske config` and `huske devices` — machine-friendly config + device access.

Built for external UIs (the native macOS app) but equally usable by humans:
the app shells out to these instead of parsing/writing the TOML itself, so
every write goes through the same Pydantic validation as `huske run` and the
config semantics live in exactly one place.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from huske.config import (
    RuntimeConfig,
    _read_toml,
    default_user_config_path,
    load_config,
    update_user_config,
)


def _print(msg: str) -> None:
    print(msg, flush=True)


def _config_file(config_path: Path | None) -> Path:
    return config_path or default_user_config_path()


def show_config(config_path: Path | None = None, json_output: bool = False) -> int:
    """Print the effective config (defaults → file → nothing else).

    JSON shape (stable for the app):
    ``{"path", "exists", "file": {...}, "effective": {...}}`` where ``file``
    holds only the keys explicitly set in the TOML and ``effective`` is the
    full validated ``RuntimeConfig``.
    """
    target = _config_file(config_path)
    file_data = _read_toml(target)
    try:
        cfg = load_config(config_path=config_path)
    except ValueError as exc:
        if json_output:
            _print(json.dumps({"error": str(exc), "path": str(target)}))
        else:
            _print(f"[error] config: {exc}")
        return 2

    if json_output:
        _print(
            json.dumps(
                {
                    "path": str(target),
                    "exists": target.exists(),
                    "file": file_data,
                    "effective": cfg.model_dump(mode="json"),
                },
                indent=2,
                default=str,
            )
        )
        return 0

    _print(f"# {target}{'' if target.exists() else '  (not created yet)'}")
    for key, value in cfg.model_dump(mode="json").items():
        marker = "*" if key in file_data else " "
        _print(f"{marker} {key} = {value!r}")
    _print("\n(* = set explicitly in the config file; everything else is a default)")
    return 0


def _parse_value(raw: str) -> Any:
    """Interpret a CLI value: JSON scalar if it parses, bare string otherwise.

    ``true``/``false``/numbers/quoted strings/null come out typed; anything
    else (e.g. ``~/huske/transcripts`` or ``MacBook Pro Microphone``) stays a
    plain string.
    """
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def set_config_value(
    key: str, raw_value: str, config_path: Path | None = None
) -> int:
    """Validate then persist ``key = value`` into the user TOML."""
    value = _parse_value(raw_value)
    target = _config_file(config_path)
    merged = {**_read_toml(target), key: value}
    try:
        RuntimeConfig(**merged)
    except ValidationError as exc:
        first = exc.errors()[0]
        loc = ".".join(str(p) for p in first.get("loc", ())) or key
        _print(f"[error] {loc}: {first.get('msg', 'invalid value')}")
        return 2
    written = update_user_config({key: value}, config_path=config_path)
    _print(f"{key} = {value!r}  → {written}")
    return 0


def unset_config_value(key: str, config_path: Path | None = None) -> int:
    """Remove ``key`` from the user TOML (reverting to the default)."""
    if key not in RuntimeConfig.model_fields:
        _print(f"[error] unknown config key: {key}")
        return 2
    target = _config_file(config_path)
    if key not in _read_toml(target):
        _print(f"{key} was not set  ({target})")
        return 0
    written = update_user_config({key: None}, config_path=config_path)
    default = RuntimeConfig.model_fields[key].get_default(call_default_factory=True)
    _print(f"{key} unset (default: {default!r})  → {written}")
    return 0


def list_devices(config_path: Path | None = None, json_output: bool = False) -> int:
    """List microphone input devices and how the configured one resolves."""
    from huske.capture.devices import (
        list_input_devices,
        resolve_input_device_with_fallback,
    )

    try:
        cfg = load_config(config_path=config_path)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    devices = list_input_devices()
    resolution = resolve_input_device_with_fallback(cfg.input_device)

    if json_output:
        _print(
            json.dumps(
                {
                    "configured": cfg.input_device,
                    "resolved_index": (
                        resolution.device.index if resolution.device else None
                    ),
                    "fallback_used": resolution.fallback_used,
                    "warning": resolution.warning,
                    "devices": [
                        {
                            "index": d.index,
                            "name": d.name,
                            "channels": d.max_input_channels,
                            "sample_rate": d.default_samplerate,
                            "host_api": d.host_api,
                        }
                        for d in devices
                    ],
                },
                indent=2,
            )
        )
        return 0

    if not devices:
        _print("no input devices found")
        return 1
    current = resolution.device.index if resolution.device else None
    for d in devices:
        marker = "●" if d.index == current else " "
        _print(f"{marker} [{d.index}] {d.name}  ({d.max_input_channels}ch, {d.default_samplerate:.0f} Hz)")
    if resolution.warning:
        _print(f"\n[warn] {resolution.warning}")
    return 0
