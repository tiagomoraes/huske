"""The SCK system-audio module must not import pyobjc at module scope.

`huske.capture.system_audio` is imported eagerly by the recording pipeline
(coordinator.py -> run_loop.py on every `huske run`/`huske recover`), but the
heavy ScreenCaptureKit / CoreMedia / Foundation wrappers are only needed when
the SCK fallback path actually starts. Keeping those imports lazy avoids paying
their RAM/startup cost on the common Core Audio tap path or when system audio is
off. This guards against a regression that re-hoists them to module top.
"""

from __future__ import annotations

import importlib


def test_system_audio_does_not_bind_pyobjc_at_module_scope() -> None:
    sa = importlib.import_module("huske.capture.system_audio")

    leaked = [
        name
        for name in ("SCK", "objc", "NSObject", "_StreamOutput", "CMSampleBufferGetNumSamples")
        if hasattr(sa, name)
    ]
    assert not leaked, f"pyobjc names leaked into module scope: {leaked}"


def test_system_audio_public_api_importable_without_pyobjc() -> None:
    # These names must resolve from a bare module import (no pyobjc required),
    # since coordinator.py references SystemAudioPermissionError at runtime.
    sa = importlib.import_module("huske.capture.system_audio")
    assert hasattr(sa, "SystemAudioStream")
    assert hasattr(sa, "SystemAudioPermissionError")
    assert hasattr(sa, "check_permission")
    assert issubclass(sa.SystemAudioPermissionError, RuntimeError)
