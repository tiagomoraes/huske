"""Background distillation thread: turn finalized transcripts into Statements.

The thread coordinates either the private MLX subprocess or loopback Ollama
I/O without blocking the ~50 ms audio drainer.

A distillation failure (daemon down, model not pulled) is **non-fatal**: the
transcript stays on disk and the next session's reconcile — or ``huske
distill`` — regenerates the sidecar. We never block recording on the LLM.
"""

from __future__ import annotations

import hashlib
import queue
import threading
from pathlib import Path
from typing import Any

from huske.distill.client import DistillError
from huske.distill.distiller import Distiller, distill_transcript
from huske.distill.sidecar import read_sidecar, sidecar_is_current, write_sidecar
from huske.search.parser import ParseError

_SENTINEL = "__STOP__"


def iter_transcripts(output_root: Path) -> list[Path]:
    """Transcript files under ``output_root`` (``YYYY-MM-DD/*.md``), sans READMEs."""
    if not output_root.exists():
        return []
    return sorted(p for p in output_root.glob("*/*.md") if p.name.lower() != "readme.md")


class DistillWorker:
    """Distills transcripts into Statement sidecars in a background daemon thread."""

    def __init__(
        self,
        output_root: Path,
        distiller: Distiller,
        *,
        max_statements_per_passage: int = 8,
        reconcile_on_start: bool = False,
    ) -> None:
        self._output_root = output_root.resolve()
        self._distiller = distiller
        self._max = max_statements_per_passage
        self._reconcile_on_start = reconcile_on_start
        self._queue: queue.Queue[str] = queue.Queue()
        self._events: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, name="huske-distill", daemon=True)
        self._thread.start()

    def submit(self, transcript_path: str) -> None:
        """Enqueue an absolute transcript path for distillation (non-blocking)."""
        self._queue.put(transcript_path)

    def reconcile(self) -> int:
        """Enqueue every transcript that lacks a current sidecar. Returns the count."""
        enqueued = 0
        for path in iter_transcripts(self._output_root):
            try:
                source_sha = hashlib.sha256(path.read_bytes()).hexdigest()
            except OSError:
                continue
            if sidecar_is_current(path, source_sha):
                continue
            self.submit(str(path))
            enqueued += 1
        return enqueued

    def poll_event(self, timeout: float = 0.0) -> dict[str, Any] | None:
        try:
            return self._events.get(timeout=timeout)
        except queue.Empty:
            return None

    def stop(self, drain_timeout: float = 10.0) -> None:
        if self._thread is None:
            return
        self._stop.set()
        self._queue.put(_SENTINEL)  # wake the thread if it is blocked on get()
        self._thread.join(timeout=drain_timeout)
        self._thread = None
        # The built-in MLX distiller owns an LLM subprocess; release it.
        closer = getattr(self._distiller, "close", None)
        if callable(closer):
            try:
                closer()
            except Exception:
                pass

    @property
    def alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    # -- worker loop -------------------------------------------------------

    def _loop(self) -> None:
        if self._reconcile_on_start:
            try:
                n = self.reconcile()
                self._emit(ok=True, reconcile=n)
            except Exception as exc:  # a sweep failure must not kill the thread
                self._emit(ok=False, error=f"reconcile failed: {exc}")
        while True:
            if self._stop.is_set() and self._queue.empty():
                return
            try:
                path = self._queue.get(timeout=0.25)
            except queue.Empty:
                continue
            if path == _SENTINEL:
                continue
            self._process(path)

    def _process(self, path_str: str) -> None:
        path = Path(path_str)
        try:
            source_sha = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as exc:
            self._emit(ok=False, path=path_str, error=f"could not read transcript: {exc}")
            return

        # Already distilled from this exact content; skip the LLM call.
        if sidecar_is_current(path, source_sha):
            existing = read_sidecar(path)
            n = len(existing.statements) if existing else 0
            self._emit(ok=True, path=path_str, statements=n, skipped=True)
            return

        try:
            sidecar = distill_transcript(
                path, self._distiller, max_statements_per_passage=self._max
            )
        except ParseError as exc:
            self._emit(ok=False, path=path_str, error=f"unparseable transcript: {exc}")
            return
        except DistillError as exc:
            # Daemon unreachable / model missing — surface as "unavailable" so the
            # run loop can show one sticky warning instead of spamming per chunk.
            self._emit(ok=False, path=path_str, error=str(exc), unavailable=exc.retryable)
            return
        except Exception as exc:  # never let one bad transcript kill the thread
            self._emit(ok=False, path=path_str, error=f"distill failed: {exc}")
            return

        write_sidecar(path, sidecar)
        n = len(sidecar.statements)
        self._emit(ok=True, path=path_str, statements=n)

    def _emit(self, **event: Any) -> None:
        self._events.put(event)
