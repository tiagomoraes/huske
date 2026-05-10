"""`huske doctor` — validate audio, model, paths."""

from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import sounddevice as sd
from rich.console import Console

from huske import __version__
from huske.capture.devices import (
    list_input_devices,
    resolve_input_device,
)
from huske.config import load_config


@dataclass
class Check:
    name: str
    ok: bool
    detail: str
    hint: str | None = None


def _peak_levels(device_index: int, channels: int, seconds: float) -> tuple[float, ...]:
    sr = 48000
    frames = int(sr * seconds)
    data = sd.rec(
        frames,
        samplerate=sr,
        channels=channels,
        dtype="float32",
        device=device_index,
    )
    sd.wait()
    if data.size == 0:
        return tuple([-120.0] * channels)
    peaks = np.abs(data).max(axis=0)
    out: list[float] = []
    for p in peaks:
        if p <= 1e-6:
            out.append(-120.0)
        else:
            out.append(float(20 * np.log10(min(float(p), 1.0))))
    return tuple(out)


def run_doctor(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
    json_output: bool = False,
) -> int:
    cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    console = Console()
    checks: list[Check] = []

    # Python.
    py_ver = ".".join(map(str, sys.version_info[:3]))
    py_ok = sys.version_info >= (3, 11)
    checks.append(Check("Python", py_ok, f"{py_ver}", None if py_ok else "Need Python 3.11+"))

    # huske version.
    checks.append(Check("huske version", True, __version__))

    # mlx-whisper importable.
    try:
        import importlib.metadata as _md

        import mlx_whisper  # noqa: F401

        version = _md.version("mlx-whisper")
        checks.append(Check("mlx-whisper", True, version))
    except Exception as exc:
        checks.append(
            Check(
                "mlx-whisper",
                False,
                str(exc),
                "pip install 'mlx-whisper>=0.4' (Apple Silicon Mac only).",
            )
        )

    # Model cached check (does not download — we attempt to load only at run time).
    checks.append(
        Check(
            "model",
            True,
            f"'{cfg.model}' will be downloaded on first use if missing",
        )
    )

    # sounddevice working.
    try:
        host_apis = list(sd.query_hostapis())
        checks.append(
            Check("sounddevice", True, f"{len(host_apis)} host API(s) detected")
        )
    except Exception as exc:
        checks.append(
            Check(
                "sounddevice",
                False,
                str(exc),
                "Reinstall sounddevice or check audio drivers.",
            )
        )

    # Resolve + validate microphone.
    devices = list_input_devices()
    device = resolve_input_device(cfg.input_device)
    if device is None:
        checks.append(
            Check(
                "microphone",
                False,
                "no input device found",
                "Connect a microphone (built-in or USB) and re-run.",
            )
        )
    else:
        detail = f"'{device.name}' ({device.max_input_channels}ch, {device.default_samplerate:.0f} Hz)"
        checks.append(Check("microphone", True, detail))

    # Mic sample.
    if device is not None and device.max_input_channels >= 1:
        try:
            peaks = _peak_levels(device.index, 1, 1.0)
            peak_str = ", ".join(f"{p:.1f} dB" for p in peaks)
            audible = any(p > -50 for p in peaks)
            checks.append(
                Check(
                    "mic sample",
                    True,
                    f"peak {peak_str} {'(audible)' if audible else '(silent — try speaking)'}",
                )
            )
        except Exception as exc:
            checks.append(
                Check(
                    "mic sample",
                    False,
                    str(exc),
                    "Check System Settings → Privacy & Security → Microphone.",
                )
            )

    # Screen Recording permission (system audio via ScreenCaptureKit).
    try:
        from huske.capture.system_audio import check_permission as _check_sa

        granted = _check_sa(timeout=5.0)
        if granted:
            checks.append(
                Check(
                    "system audio",
                    True,
                    "Screen Recording permission granted — ScreenCaptureKit usable",
                )
            )
        else:
            checks.append(
                Check(
                    "system audio",
                    False,
                    "Screen Recording permission not granted",
                    "Open System Settings → Privacy & Security → Screen Recording, "
                    "enable Python (or your launcher), then restart huske.",
                )
            )
    except ImportError:
        checks.append(
            Check(
                "system audio",
                False,
                "ScreenCaptureKit framework unavailable",
                "Requires macOS 13+. Install pyobjc-framework-ScreenCaptureKit.",
            )
        )
    except Exception as exc:
        checks.append(
            Check(
                "system audio",
                False,
                f"could not query permission: {exc}",
                "Try `huske run` once to trigger the permission prompt.",
            )
        )

    # Output paths writable.
    for label, path in [("output root", cfg.output_root), ("audio root", cfg.audio_root)]:
        try:
            path.mkdir(parents=True, exist_ok=True)
            test = path / ".huske_write_test"
            test.write_text("ok", encoding="utf-8")
            test.unlink()
            checks.append(Check(label, True, f"writable: {path}"))
        except OSError as exc:
            checks.append(
                Check(
                    label,
                    False,
                    f"{path}: {exc}",
                    "Choose a writable --output-root / --audio-root.",
                )
            )

    # Render.
    if json_output:
        payload = {
            "version": __version__,
            "ok": all(c.ok for c in checks),
            "checks": [asdict(c) for c in checks],
            "input_devices": [
                {
                    "index": d.index,
                    "name": d.name,
                    "channels": d.max_input_channels,
                    "sample_rate": d.default_samplerate,
                }
                for d in devices
            ],
        }
        print(json.dumps(payload, indent=2))
    else:
        console.print(f"\n[bold cyan]huske doctor[/bold cyan]  v{__version__}\n")
        for c in checks:
            mark = "[green]✓[/green]" if c.ok else "[red]✗[/red]"
            console.print(f"  {mark} [bold]{c.name:18s}[/bold] {c.detail}")
            if not c.ok and c.hint:
                console.print(f"     [yellow]hint:[/yellow] {c.hint}")
        console.print("")
        if all(c.ok for c in checks):
            console.print("[green]All checks passed.[/green]\n")
        else:
            console.print("[red]Some checks failed — see hints above.[/red]\n")

    if not any(c.name == "microphone" and c.ok for c in checks):
        return 3
    return 0 if all(c.ok for c in checks) else 1
