"""Background replication thread: push finalized transcripts off the hot path.

Why a *thread* (not a subprocess like the embed/transcribe workers)? Those
isolate heavy, GIL-holding, Metal-contending compute. Replication is network
I/O, which releases the GIL while it waits — it cannot starve the ~50 ms audio
drainer, so a daemon thread is the right, lighter tool. The recording loop only
ever calls :meth:`submit` (a queue put); everything else happens here.

On a retryable failure the item is re-queued with bounded exponential backoff,
so a Mac that briefly loses connectivity mid-session catches up without a hot
loop. Anything still unsent when the process exits is picked up by the next
:meth:`reconcile` at startup (the durable :class:`Outbox` is the memory).
"""

from __future__ import annotations

import queue
import threading
from pathlib import Path
from typing import Any

from huske.sync.client import IngestClient, SyncError, sha256_hex
from huske.sync.outbox import Outbox

_SENTINEL = "__STOP__"


def iter_transcripts(output_root: Path) -> list[Path]:
    """Transcript files under ``output_root`` (``YYYY-MM-DD/*.md``), sans READMEs.

    A deliberate 3-line copy of ``huske.search.indexer.iter_transcripts`` so the
    base-install sync client imports nothing from the optional search subsystem.
    """
    if not output_root.exists():
        return []
    return sorted(p for p in output_root.glob("*/*.md") if p.name.lower() != "readme.md")


class SyncWorker:
    """Pushes transcripts to a huske server in a background daemon thread."""

    def __init__(
        self,
        output_root: Path,
        outbox: Outbox,
        client: IngestClient,
        *,
        max_attempts: int = 6,
        reconcile_on_start: bool = False,
    ) -> None:
        self._output_root = output_root.resolve()
        self._outbox = outbox
        self._client = client
        self._max_attempts = max_attempts
        self._reconcile_on_start = reconcile_on_start
        self._queue: queue.Queue[str] = queue.Queue()
        self._events: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, name="huske-sync", daemon=True)
        self._thread.start()

    def submit(self, transcript_path: str) -> None:
        """Enqueue an absolute transcript path for replication (non-blocking)."""
        self._queue.put(transcript_path)

    def reconcile(self) -> int:
        """Enqueue every transcript the server has not yet acknowledged.

        Run at startup so a Mac that recorded while offline (or before sync was
        configured) catches the server up. Returns the number enqueued.
        """
        enqueued = 0
        for path in iter_transcripts(self._output_root):
            rel = self._rel_path(path)
            if rel is None:
                continue
            try:
                content = path.read_text(encoding="utf-8")
            except OSError:
                continue
            if self._outbox.is_sent(rel, sha256_hex(content)):
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

    @property
    def alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    # -- worker loop -------------------------------------------------------

    def _loop(self) -> None:
        # Reconcile in-thread (not at submit time) so a first whole-corpus sweep
        # never stalls session startup on the main thread.
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
            self._process(path, draining=self._stop.is_set())

    def _process(self, path_str: str, *, draining: bool) -> None:
        path = Path(path_str)
        rel = self._rel_path(path)
        if rel is None:
            self._emit(ok=False, rel_path=path_str, error="transcript is outside output_root")
            return
        try:
            content = path.read_text(encoding="utf-8")
        except OSError as exc:
            self._emit(ok=False, rel_path=rel, error=f"could not read transcript: {exc}")
            return

        digest = sha256_hex(content)
        if self._outbox.is_sent(rel, digest):
            self._emit(ok=True, rel_path=rel, status="unchanged", skipped=True)
            return

        try:
            result = self._client.push(rel, content, digest)
        except SyncError as exc:
            attempts = self._outbox.record_failure(rel, str(exc))
            self._emit(ok=False, rel_path=rel, error=str(exc), attempts=attempts)
            if not draining and exc.retryable and attempts < self._max_attempts:
                delay = min(30.0, 2.0 ** min(attempts, 5))
                # wait() returns True if we were told to stop during the backoff,
                # in which case we abandon the retry rather than re-queue.
                if not self._stop.wait(delay):
                    self._queue.put(path_str)
            return

        self._outbox.mark_sent(rel, digest)
        self._emit(ok=True, rel_path=rel, status=result.status)

    def _rel_path(self, path: Path) -> str | None:
        try:
            return path.resolve().relative_to(self._output_root).as_posix()
        except ValueError:
            return None

    def _emit(self, **event: Any) -> None:
        self._events.put(event)
