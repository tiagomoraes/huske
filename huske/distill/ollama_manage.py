"""Best-effort local management of the Ollama daemon for distillation.

huske does not bundle an LLM (ADR 0005); distillation calls a local Ollama
daemon over loopback HTTP. To make the opt-in feel more standalone, when the
user turns distillation on huske will — if ``distill_auto_manage`` is set —
best-effort:

1. **start the daemon** (`ollama serve`) when the CLI is installed but nothing
   is listening, and
2. **pull the configured model** (streaming `POST /api/pull`) when it is missing.

Both steps are bounded and never installs Ollama itself; if either can't be
done, ``ensure_ready`` returns the same not-ready :class:`Readiness` the caller
would have surfaced anyway (with its actionable hint). All of this runs off the
main loop (the callers invoke it from a background thread), so the daemon start's
poll loop and the multi-minute model download never stall the audio drainer.
"""

from __future__ import annotations

import shutil
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from huske.distill.client import DistillError, OllamaClient
from huske.distill.health import Readiness, probe_distill

# (severity, message) sink, matching run_loop's on_event / state.push_event.
Emit = Callable[[str, str], None]


class PullAborted(RuntimeError):
    """Raised through an ``on_progress`` callback to stop an in-flight pull."""


def ollama_cli() -> str | None:
    """Absolute path to the ``ollama`` CLI on PATH, or ``None`` if not installed."""
    return shutil.which("ollama")


def daemon_reachable(endpoint: str, *, timeout: float = 2.0) -> bool:
    """True if the daemon answers ``/api/tags`` at ``endpoint`` within ``timeout``."""
    try:
        OllamaClient(endpoint, timeout=timeout).list_models()
        return True
    except DistillError:
        return False


def start_daemon(
    endpoint: str,
    *,
    log: Path | None = None,
    wait: float = 20.0,
    should_abort: Callable[[], bool] | None = None,
) -> bool:
    """Spawn ``ollama serve`` detached and wait until the API answers.

    Returns True if the daemon is reachable afterwards (immediately True if it
    already was), False if the CLI is missing, the spawn fails, or it doesn't
    come up within ``wait`` seconds.
    """
    if daemon_reachable(endpoint):
        return True
    cli = ollama_cli()
    if cli is None:
        return False
    stderr_f = None
    try:
        if log is not None:
            stderr_f = open(log, "ab")
        subprocess.Popen(
            [cli, "serve"],
            stdout=subprocess.DEVNULL,
            stderr=(stderr_f or subprocess.DEVNULL),
            start_new_session=True,
        )
    except OSError:
        return False
    finally:
        if stderr_f is not None:
            stderr_f.close()

    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if should_abort is not None and should_abort():
            return False
        if daemon_reachable(endpoint):
            return True
        time.sleep(0.4)
    return daemon_reachable(endpoint)


def pull_model(
    endpoint: str,
    model: str,
    *,
    on_progress: Callable[[str, int, int], None] | None = None,
    timeout: float = 600.0,
) -> None:
    """Pull ``model`` via the daemon's streaming pull API. Raises on failure."""
    OllamaClient(endpoint, timeout=timeout).pull(model, on_progress=on_progress)


def _progress_emitter(
    emit: Emit | None,
    model: str,
    should_abort: Callable[[], bool] | None,
    *,
    interval: float = 2.0,
) -> Callable[[str, int, int], None]:
    """Throttle Ollama pull progress into at most one ``emit`` per ``interval``."""
    last = [0.0]

    def cb(status: str, completed: int, total: int) -> None:
        if should_abort is not None and should_abort():
            raise PullAborted()
        if emit is None:
            return
        now = time.monotonic()
        if total > 0 and (now - last[0]) >= interval:
            last[0] = now
            emit("info", f"distillation: pulling {model} — {completed * 100 // total}%")

    return cb


def ensure_ready(
    model: str,
    *,
    backend: str = "ollama",
    endpoint: str = "http://127.0.0.1:11434",
    auto_manage: bool = True,
    emit: Emit | None = None,
    should_abort: Callable[[], bool] | None = None,
    serve_log: Path | None = None,
    start_wait: float = 20.0,
) -> Readiness:
    """Probe distillation readiness and, if ``auto_manage``, try to fix it.

    Returns the final :class:`Readiness`. When already ready (or auto-management
    is off, or the backend isn't Ollama) this is just the probe. Otherwise it
    starts the daemon and/or pulls the model, re-probing after each step, and
    returns whatever state it could reach.
    """
    r = probe_distill(model, backend=backend, endpoint=endpoint)
    if r.ok or not auto_manage or backend != "ollama" or model in ("heuristic", "fake"):
        return r

    if r.reason == "unreachable":
        if ollama_cli() is None:
            return r  # can't auto-start; caller surfaces the "install/start" hint
        _emit(emit, "info", "distillation: starting ollama daemon…")
        if start_daemon(endpoint, log=serve_log, wait=start_wait, should_abort=should_abort):
            _emit(emit, "info", "distillation: ollama daemon started")
        r = probe_distill(model, backend=backend, endpoint=endpoint)
        if r.ok:
            return r

    if r.reason == "model_missing":
        if should_abort is not None and should_abort():
            return r
        _emit(emit, "info", f"distillation: pulling {model} (first run — may take a few minutes)…")
        try:
            pull_model(
                endpoint, model, on_progress=_progress_emitter(emit, model, should_abort)
            )
        except PullAborted:
            return r
        except DistillError as exc:
            _emit(emit, "warn", f"distillation: pull failed: {exc}")
            return probe_distill(model, backend=backend, endpoint=endpoint)
        _emit(emit, "info", f"distillation: pulled {model}")
        r = probe_distill(model, backend=backend, endpoint=endpoint)

    return r


def _emit(emit: Emit | None, severity: str, message: str) -> None:
    if emit is not None:
        emit(severity, message)
