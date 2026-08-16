"""Metal / process-footprint helpers for the ASR and distill children.

Apple Silicon unified memory does not give discrete VRAM back when a Python
reference is dropped. MLX keeps freed buffers in a cache whose default limit
is ~1.5x the GPU recommended working set (often the whole machine). These
helpers:

- cap that cache and the evaluation memory guideline
- empty the cache after each job
- serialize the two Metal clients (ASR wins)
- report RSS for the control snapshot
"""

from __future__ import annotations

import os
import subprocess
import threading
from typing import Any, Protocol

DEFAULT_CACHE_LIMIT_MB = 512
DEFAULT_ASR_MEMORY_LIMIT_MB = 8192
DEFAULT_LLM_MEMORY_LIMIT_MB = 6144


class DistillerLike(Protocol):
    model_id: str
    backend: str

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]: ...


def configure_mlx_limits(
    *,
    cache_limit_mb: int = DEFAULT_CACHE_LIMIT_MB,
    memory_limit_mb: int = DEFAULT_ASR_MEMORY_LIMIT_MB,
    wired_limit_mb: int = 0,
) -> None:
    """Apply cache / memory / wired caps. Safe to call before or after first eval."""
    import mlx.core as mx

    if cache_limit_mb >= 0:
        mx.set_cache_limit(int(cache_limit_mb) * 1024 * 1024)
    if memory_limit_mb > 0:
        mx.set_memory_limit(int(memory_limit_mb) * 1024 * 1024)
    # 0 is the MLX default and the safe value on 16-18 GB daily-driver Macs.
    # mlx-lm.generate() otherwise wires max_recommended_working_set_size.
    try:
        mx.set_wired_limit(int(wired_limit_mb) * 1024 * 1024)
    except Exception:
        pass


def reclaim_mlx() -> None:
    """Drop the Metal buffer cache. Active model weights stay until unloaded."""
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:
        pass
    try:
        import gc

        gc.collect()
    except Exception:
        pass


def mlx_memory_mb() -> dict[str, float]:
    """Live MLX counters in mebibytes. Zeros when MLX is not imported."""
    try:
        import mlx.core as mx

        return {
            "active_mb": mx.get_active_memory() / (1024 * 1024),
            "cache_mb": mx.get_cache_memory() / (1024 * 1024),
            "peak_mb": mx.get_peak_memory() / (1024 * 1024),
        }
    except Exception:
        return {"active_mb": 0.0, "cache_mb": 0.0, "peak_mb": 0.0}


def rss_bytes_by_pid(pids: list[int]) -> dict[int, int]:
    """Current RSS in bytes for each live pid (best-effort, one ``ps``)."""
    wanted = [int(p) for p in pids if int(p) > 0]
    if not wanted:
        return {}
    try:
        out = subprocess.check_output(
            ["ps", "-o", "pid=,rss=", "-p", ",".join(str(p) for p in wanted)],
            text=True,
            timeout=0.5,
        )
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    found: dict[int, int] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            found[int(parts[0])] = int(parts[1]) * 1024
        except ValueError:
            continue
    return found


def rss_mb(pid: int | None = None) -> float:
    pid = os.getpid() if pid is None else int(pid)
    return rss_bytes_by_pid([pid]).get(pid, 0) / (1024 * 1024)


class MetalGate:
    """Serialize the two Metal clients. ASR has priority.

    The capture mixer must never block here. Queue demand from the mixer
    thread; the main loop calls :meth:`try_begin_asr`. The distill thread
    calls :meth:`acquire_llm` / :meth:`release_llm` around each passage.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cv = threading.Condition(self._lock)
        self._asr_inflight = 0
        self._asr_waiting = False
        self._llm_held = False

    def try_begin_asr(self, has_job: bool) -> bool:
        """Start one ASR job if the LLM is not holding Metal.

        When the LLM is mid-passage, records that ASR is waiting so the next
        ``acquire_llm`` yields. Returns False until the LLM releases.
        """
        with self._cv:
            if not has_job:
                self._asr_waiting = False
                return False
            if self._llm_held:
                self._asr_waiting = True
                return False
            self._asr_waiting = False
            self._asr_inflight += 1
            return True

    def finish_asr(self) -> None:
        with self._cv:
            if self._asr_inflight > 0:
                self._asr_inflight -= 1
            self._cv.notify_all()

    def acquire_llm(self) -> None:
        """Block until no ASR job is running or waiting."""
        with self._cv:
            while self._asr_inflight > 0 or self._asr_waiting or self._llm_held:
                self._cv.wait()
            self._llm_held = True

    def release_llm(self) -> None:
        with self._cv:
            self._llm_held = False
            self._cv.notify_all()

    @property
    def llm_held(self) -> bool:
        with self._lock:
            return self._llm_held

    @property
    def asr_inflight(self) -> int:
        with self._lock:
            return self._asr_inflight


class GatedDistiller:
    """Wrap a Distiller so each passage waits for the Metal gate."""

    def __init__(self, inner: DistillerLike, gate: MetalGate) -> None:
        self._inner = inner
        self._gate = gate
        self.model_id = inner.model_id
        self.backend = inner.backend

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]:
        self._gate.acquire_llm()
        try:
            return self._inner.distill_passage(text, sources=sources, language=language)
        finally:
            self._gate.release_llm()

    def close(self) -> None:
        closer = getattr(self._inner, "close", None)
        if callable(closer):
            closer()

    def __getattr__(self, name: str) -> Any:
        return getattr(self._inner, name)
