"""Audio device enumeration and validation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import sounddevice as sd


@dataclass
class DeviceInfo:
    index: int
    name: str
    max_input_channels: int
    default_samplerate: float
    host_api: str

    @classmethod
    def from_sd(cls, idx: int, raw: dict[str, Any], host_apis: list[dict[str, Any]]) -> DeviceInfo:
        return cls(
            index=idx,
            name=raw["name"],
            max_input_channels=int(raw["max_input_channels"]),
            default_samplerate=float(raw["default_samplerate"]),
            host_api=host_apis[raw["hostapi"]]["name"],
        )


@dataclass
class ValidationReport:
    ok: bool
    device: DeviceInfo | None
    issues: list[str]
    suggestions: list[str]


@dataclass
class DeviceResolution:
    device: DeviceInfo | None
    requested_name: str | None
    fallback_used: bool = False
    warning: str | None = None


def list_input_devices() -> list[DeviceInfo]:
    host_apis = list(sd.query_hostapis())
    raw_devices = sd.query_devices()
    out: list[DeviceInfo] = []
    for i, raw in enumerate(raw_devices):
        if int(raw.get("max_input_channels", 0)) > 0:
            out.append(DeviceInfo.from_sd(i, raw, host_apis))
    return out


def match_input_device(devices: list[DeviceInfo], name: str) -> DeviceInfo | None:
    needle = name.lower()
    for d in devices:
        if d.name.lower() == needle:
            return d
    # Substring fallback (e.g., "MacBook Pro" matches "MacBook Pro Microphone").
    for d in devices:
        if needle in d.name.lower():
            return d
    return None


def _default_input_device(devices: list[DeviceInfo]) -> DeviceInfo | None:
    # System default input.
    try:
        default_idx = sd.default.device[0]
    except Exception:
        default_idx = -1
    if default_idx >= 0:
        host_apis = list(sd.query_hostapis())
        raw = sd.query_devices(default_idx)
        return DeviceInfo.from_sd(default_idx, dict(raw), host_apis)
    return devices[0] if devices else None


def resolve_input_device(name: str | None) -> DeviceInfo | None:
    """Resolve a device name (case-insensitive substring match) or return system default."""
    return resolve_input_device_with_fallback(name).device


def resolve_input_device_with_fallback(name: str | None) -> DeviceResolution:
    """Resolve the preferred input, falling back to the system default if absent."""
    devices = list_input_devices()
    if name:
        matched = match_input_device(devices, name)
        if matched is not None:
            return DeviceResolution(device=matched, requested_name=name)
        fallback = _default_input_device(devices)
        if fallback is not None:
            return DeviceResolution(
                device=fallback,
                requested_name=name,
                fallback_used=True,
                warning=(
                    f"Configured microphone '{name}' was not found; "
                    f"using default microphone '{fallback.name}'."
                ),
            )
        return DeviceResolution(
            device=None,
            requested_name=name,
            warning=f"Configured microphone '{name}' was not found.",
        )
    return DeviceResolution(device=_default_input_device(devices), requested_name=None)


def validate_device(device: DeviceInfo | None) -> ValidationReport:
    """Validate a microphone device. System audio has its own backend."""
    issues: list[str] = []
    suggestions: list[str] = []

    if device is None:
        issues.append("No usable microphone found.")
        suggestions.append(
            "Connect a built-in or USB microphone and re-run. "
            "System audio capture is handled by its own macOS backend."
        )
        return ValidationReport(ok=False, device=None, issues=issues, suggestions=suggestions)

    if device.max_input_channels < 1:
        issues.append(f"Device '{device.name}' has no input channels.")

    return ValidationReport(
        ok=not issues,
        device=device,
        issues=issues,
        suggestions=suggestions,
    )
