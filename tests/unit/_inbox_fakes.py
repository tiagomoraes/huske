"""Shared fakes for the engine-inbox tests: synthetic audio + an in-process ASR.

``InlineWorker`` runs the real ``huske.transcribe.worker._worker_main`` loop on
a thread with plain ``queue.Queue``s, MLX stubbed out and ``build_engine``
returning :class:`FakeEngine`, so the tests exercise the worker's real job
handling (frontmatter, filenames, ``job_id`` echo, overwrite, audio cleanup)
without Metal or a model download.
"""

from __future__ import annotations

import queue
import sys
import threading
import types
from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf

from huske.config import RuntimeConfig
from huske.transcribe import worker as worker_mod
from huske.transcribe.engines.base import Segment

SR = 16_000


def tone(seconds: float, *, sr: int = SR, freq: float = 220.0, amp: float = 0.3) -> np.ndarray:
    t = np.arange(round(seconds * sr), dtype=np.float32) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def silence(seconds: float, *, sr: int = SR) -> np.ndarray:
    return np.zeros(round(seconds * sr), dtype=np.float32)


def write_wav(path: Path, audio: np.ndarray, sr: int = SR) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), audio, sr, subtype="PCM_16")
    return path


def make_cfg(tmp_path: Path, **overrides: Any) -> RuntimeConfig:
    values: dict[str, Any] = {
        "output_root": tmp_path / "transcripts",
        "audio_root": tmp_path / "audio",
        "logs_root": tmp_path / "logs",
        "inbox_root": tmp_path / "inbox",
        "chunk_minutes": 1.0,
        **overrides,
    }
    return RuntimeConfig(**values)


class FakeEngine:
    """Says how long each non-silent piece is; optionally fails N times."""

    model_label = "fake:test"

    def __init__(self, fail_times: int = 0) -> None:
        self.fail_times = fail_times
        self.calls = 0
        self.options: list[dict[str, object]] = []

    def set_options(self, **options: object) -> None:
        self.options.append(options)

    def transcribe(self, audio: np.ndarray) -> list[Segment]:
        self.calls += 1
        if self.calls <= self.fail_times:
            raise RuntimeError("synthetic engine failure")
        if audio.size == 0 or float(np.sqrt(np.mean(audio * audio))) < 1e-3:
            return []
        seconds = audio.size / SR
        return [Segment(start=0.0, end=seconds, text=f"speech for {seconds:.1f} seconds")]

    def unload(self) -> None:
        return None


def install_fake_asr(monkeypatch: pytest.MonkeyPatch, engine: FakeEngine) -> None:
    """Make ``_worker_main`` runnable on a thread with ``engine`` as the ASR."""
    fake_core = types.ModuleType("mlx.core")
    fake_core.eval = lambda *a, **k: None  # type: ignore[attr-defined]
    fake_core.zeros = lambda *a, **k: 0  # type: ignore[attr-defined]
    fake_mlx = types.ModuleType("mlx")
    fake_mlx.core = fake_core  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx", fake_mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", fake_core)

    import huske.mlx_runtime as mlx_runtime
    import huske.proctitle as proctitle
    import huske.transcribe.engines as engines

    monkeypatch.setattr(mlx_runtime, "configure_mlx_limits", lambda **k: None)
    monkeypatch.setattr(mlx_runtime, "reclaim_mlx", lambda: None)
    monkeypatch.setattr(mlx_runtime, "mlx_memory_mb", lambda: {})
    monkeypatch.setattr(mlx_runtime, "rss_mb", lambda pid=None: 0.0)
    monkeypatch.setattr(proctitle, "set_process_title", lambda *a, **k: None)
    monkeypatch.setattr(worker_mod, "_configure_worker_signal_handlers", lambda: None)
    monkeypatch.setattr(engines, "build_engine", lambda *a, **k: engine)


class InlineWorker:
    """``TranscriptionWorker`` API over the real worker loop, on a thread."""

    def __init__(self) -> None:
        self._in: queue.Queue[Any] = queue.Queue()
        self._out: queue.Queue[Any] = queue.Queue()
        self._thread: threading.Thread | None = None
        self.submitted: list[dict[str, Any]] = []

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._thread = threading.Thread(
            target=worker_mod._worker_main,
            args=(self._in, self._out, {"recycle_idle_process": False}),
            daemon=True,
        )
        self._thread.start()
        assert self._out.get(timeout=10) == worker_mod._READY_MSG

    def submit(self, job: dict[str, Any]) -> None:
        self.start()
        self.submitted.append(job)
        self._in.put(job)

    def poll_result(self, timeout: float = 0.0) -> dict[str, Any] | None:
        try:
            msg = self._out.get(timeout=timeout) if timeout > 0 else self._out.get_nowait()
        except queue.Empty:
            return None
        return msg if isinstance(msg, dict) else None

    def stop(self, drain_timeout: float = 60.0) -> None:
        if self._thread is None:
            return
        self._in.put(worker_mod._SENTINEL)
        self._thread.join(timeout=drain_timeout)
        self._thread = None

    @property
    def alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()


def worker_factory(workers: list[InlineWorker]) -> Callable[..., InlineWorker]:
    """A factory that records every worker it builds (for stop assertions)."""

    def build(*_: Any) -> InlineWorker:
        w = InlineWorker()
        workers.append(w)
        return w

    return build
