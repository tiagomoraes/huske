"""`huske doctor` — validate audio, model, paths."""

from __future__ import annotations

import json
import os
import sys
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import sounddevice as sd
from rich.console import Console

from huske import __version__
from huske.capture.devices import (
    list_input_devices,
    resolve_input_device_with_fallback,
)
from huske.config import RuntimeConfig, load_config


@dataclass
class Check:
    name: str
    ok: bool
    detail: str
    hint: str | None = None


@contextmanager
def _suppress_native_output(enabled: bool) -> Iterator[None]:
    """Suppress C-extension writes while building machine-readable JSON output."""
    if not enabled:
        yield
        return

    sys.stdout.flush()
    sys.stderr.flush()
    saved_stdout = os.dup(1)
    saved_stderr = os.dup(2)
    try:
        with open(os.devnull, "wb") as devnull:
            os.dup2(devnull.fileno(), 1)
            os.dup2(devnull.fileno(), 2)
            yield
            sys.stdout.flush()
            sys.stderr.flush()
    finally:
        os.dup2(saved_stdout, 1)
        os.dup2(saved_stderr, 2)
        os.close(saved_stdout)
        os.close(saved_stderr)


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


def _screen_capturekit_check(*, label: str = "system audio") -> Check:
    try:
        from huske.capture.system_audio import check_permission as _check_sa

        granted = _check_sa(timeout=5.0)
        if granted:
            return Check(
                label,
                True,
                "ScreenCaptureKit usable",
            )
        return Check(
            label,
            False,
            "Screen Recording permission not granted",
            "Open System Settings -> Privacy & Security -> Screen Recording, "
            "enable Python (or your launcher), then restart huske.",
        )
    except ImportError:
        return Check(
            label,
            False,
            "ScreenCaptureKit framework unavailable",
            "Requires macOS 13+. Install pyobjc-framework-ScreenCaptureKit.",
        )
    except Exception as exc:
        return Check(
            label,
            False,
            f"could not query ScreenCaptureKit permission: {exc}",
            "Try `huske run` once to trigger the permission prompt.",
        )


def _screen_capturekit_available_check(*, label: str = "system audio") -> Check:
    try:
        import ScreenCaptureKit as _sck  # noqa: F401
    except ImportError:
        return Check(
            label,
            False,
            "ScreenCaptureKit framework unavailable",
            "Requires macOS 13+. Install pyobjc-framework-ScreenCaptureKit.",
        )
    return Check(
        label,
        True,
        "ScreenCaptureKit available; permission not probed",
        "Run `huske doctor --system-audio-backend sck` to validate Screen Recording permission.",
    )


def _core_audio_tap_check(cfg: RuntimeConfig) -> Check:
    try:
        from huske.capture.system_audio_tap import CoreAudioTapStream, is_supported
    except ImportError:
        return Check(
            "system audio",
            False,
            "Core Audio framework unavailable",
            "Install pyobjc-framework-CoreAudio, then re-run `huske doctor`.",
        )

    if not is_supported():
        return Check(
            "system audio",
            False,
            "Core Audio process tap unavailable on this macOS",
            "Use macOS 14.4+ for screen-share-resistant system audio capture, "
            "or set system_audio_backend = 'sck' for the legacy backend.",
        )

    done = threading.Event()
    errors: list[BaseException] = []

    def probe() -> None:
        stream = CoreAudioTapStream(sample_rate=cfg.sample_rate)
        try:
            stream.start()
        except BaseException as exc:
            errors.append(exc)
        finally:
            try:
                stream.stop()
            finally:
                done.set()

    thread = threading.Thread(
        target=probe,
        name="huske-doctor-core-audio-tap-probe",
        daemon=True,
    )
    thread.start()
    if not done.wait(5.0):
        return Check(
            "system audio",
            False,
            "Core Audio process tap probe timed out",
            "macOS may be waiting for capture permission. Grant Audio Capture / "
            "Screen Recording permission if prompted, then restart huske.",
        )

    if errors:
        exc = errors[0]
        return Check(
            "system audio",
            False,
            f"Core Audio process tap unavailable: {exc}",
            "Grant Audio Capture / Screen Recording permission if macOS prompts, "
            "then restart huske. ScreenCaptureKit fallback can stop during screen sharing.",
        )

    return Check("system audio", True, "Core Audio process tap usable")


def _system_audio_checks(cfg: RuntimeConfig) -> list[Check]:
    backend = cfg.system_audio_backend
    if backend == "off":
        return [Check("system audio", True, "disabled by config (mic-only)")]

    try:
        from huske.capture.system_audio_tap import is_supported as tap_supported

        tap_available = tap_supported()
    except ImportError:
        tap_available = False

    if backend == "auto":
        effective = "Core Audio tap" if tap_available else "ScreenCaptureKit"
        checks = [Check("system backend", True, f"auto -> {effective}")]
        if tap_available:
            checks.append(
                Check(
                    "system audio",
                    True,
                    "Core Audio process tap available; permission not probed",
                    "Run `huske doctor --system-audio-backend tap` to validate capture permission.",
                )
            )
            return checks
        checks.append(_screen_capturekit_available_check())
        return checks

    if backend == "tap":
        return [
            Check("system backend", True, "forced Core Audio tap"),
            _core_audio_tap_check(cfg),
        ]

    return [
        Check(
            "system backend",
            True,
            "forced ScreenCaptureKit (may stop during screen sharing)",
        ),
        _screen_capturekit_check(),
    ]


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
        with _suppress_native_output(json_output):
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
    with _suppress_native_output(json_output):
        devices = list_input_devices()
        device_resolution = resolve_input_device_with_fallback(cfg.input_device)
    device = device_resolution.device
    if device is None:
        if device_resolution.warning:
            detail = device_resolution.warning
            hint = "Connect that microphone or update `input_device` in your config."
        else:
            detail = "no input device found"
            hint = "Connect a microphone (built-in or USB) and re-run."
        checks.append(
            Check(
                "microphone",
                False,
                detail,
                hint,
            )
        )
    else:
        detail = f"'{device.name}' ({device.max_input_channels}ch, {device.default_samplerate:.0f} Hz)"
        if device_resolution.fallback_used and device_resolution.warning:
            detail = f"{device_resolution.warning} {detail}"
        checks.append(Check("microphone", True, detail))

    # Mic sample.
    if device is not None and device.max_input_channels >= 1:
        try:
            with _suppress_native_output(json_output):
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

    # System-audio backend. Core Audio tap is preferred because ScreenCaptureKit
    # can be interrupted when another app starts screen sharing.
    with _suppress_native_output(json_output):
        system_audio_checks = _system_audio_checks(cfg)
    checks.extend(system_audio_checks)

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
