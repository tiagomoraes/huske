"""Transcribe queued inbox items through an ASR worker.

One :class:`InboxProcessor` serves both callers named by the contract:

* the **live engine** (``huske run``) constructs it with ``background=True``
  and drives it from its main loop: :meth:`InboxProcessor.poll` (retries the
  lock every ``scan_interval``, decodes/splits the next item on a background
  thread, and hands back ASR jobs), :meth:`mark_submitted`,
  :meth:`handle_result` (returns the transcripts written, for the post-write
  hooks), :meth:`check_worker`, and :meth:`release` on exit. Jobs go through
  the engine's own backlog and Metal gate, beside live chunks, so there is
  only ever one ASR model in RAM.
* a one-shot **``huske inbox process``**, which calls
  :meth:`InboxProcessor.run_pending` with a worker factory and blocks until
  every runnable item has been attempted once.

Only one piece of one item is in flight at a time. That keeps live chunks
interleaved with a long import instead of queued behind all of it, and bounds
how long a stopping engine can wait on inbox work to a single piece.

Each piece's job carries a string ``job_id`` (``inbox:<id>:<seq>``) that the
worker echoes back; results are matched on it, never on ``chunk_seq``, which
restarts at 1 for every imported recording and so collides with live chunks.
"""

from __future__ import annotations

import os
import shutil
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Protocol

from huske import paths
from huske.config import RuntimeConfig
from huske.inbox.decode import DecodeCancelled, decode_to_wav16k
from huske.inbox.split import Piece, SplitCancelled, split_wav
from huske.inbox.store import (
    MAX_ATTEMPTS,
    WORK_DIR,
    InboxItem,
    InboxLock,
    InboxStore,
    now_local,
    session_id_for,
)

JOB_ID_PREFIX = "inbox:"
SCAN_INTERVAL_SECONDS = 5.0
# The live engine waits this long after a failure before retrying the item.
RETRY_DELAY_SECONDS = 60.0
# A submitted job whose worker has been dead this long is considered lost.
LOST_WORKER_GRACE_SECONDS = 3.0
PRUNE_INTERVAL_SECONDS = 3600.0

EventSink = Callable[[str, str], None]
Decoder = Callable[..., float]
Splitter = Callable[..., list[tuple[Piece, Path]]]


def is_inbox_job_id(value: object) -> bool:
    """True for a ``job_id`` minted by the inbox (never set on live chunks)."""
    return isinstance(value, str) and value.startswith(JOB_ID_PREFIX)


class AsrWorker(Protocol):
    """The slice of :class:`huske.transcribe.worker.TranscriptionWorker` used."""

    def start(self) -> None: ...
    def submit(self, job: dict[str, Any]) -> None: ...
    def poll_result(self, timeout: float = 0.0) -> dict[str, Any] | None: ...
    def stop(self, drain_timeout: float = 60.0) -> None: ...
    @property
    def alive(self) -> bool: ...


class _Preparation:
    """Decode + split one item into piece WAVs (thread target, or inline)."""

    def __init__(
        self,
        item: InboxItem,
        *,
        work_dir: Path,
        max_seconds: float,
        prev_attempts: int,
        decoder: Decoder,
        splitter: Splitter,
    ) -> None:
        self.item = item
        self.work_dir = work_dir
        self.max_seconds = max_seconds
        self.prev_attempts = prev_attempts
        self._decoder = decoder
        self._splitter = splitter
        self.cancel = threading.Event()
        self.done = threading.Event()
        self.pieces: list[tuple[Piece, Path]] = []
        self.duration_seconds = 0.0
        self.error: str | None = None
        self.cancelled = False
        self.thread: threading.Thread | None = None

    def run(self) -> None:
        try:
            self.work_dir.mkdir(parents=True, exist_ok=True)
            decoded = self.work_dir / "decoded.wav"
            if not self.item.audio_path.is_file():
                raise FileNotFoundError(f"audio file missing: {self.item.audio_path.name}")
            self.duration_seconds = float(
                self._decoder(self.item.audio_path, decoded, cancel=self.cancel)
            )
            if self.cancel.is_set():
                raise DecodeCancelled(self.item.id)
            self.pieces = self._splitter(
                decoded, self.work_dir, max_seconds=self.max_seconds, cancel=self.cancel
            )
            decoded.unlink(missing_ok=True)
        except (DecodeCancelled, SplitCancelled):
            self.cancelled = True
        except Exception as exc:
            self.error = str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
        finally:
            self.done.set()


@dataclass
class _Active:
    item: InboxItem
    session_id: str
    started_at: datetime  # Mac-local
    work_dir: Path
    pieces: list[tuple[Piece, Path]]
    prev_attempts: int
    next_index: int = 0
    inflight: str | None = None
    submitted: bool = False
    chunks_done: int = 0
    transcripts: list[str] = field(default_factory=list)


class InboxProcessor:
    """Elects itself transcriber via the inbox lock and works the queue."""

    def __init__(
        self,
        cfg: RuntimeConfig,
        *,
        background: bool = False,
        store: InboxStore | None = None,
        on_event: EventSink | None = None,
        scan_interval: float = SCAN_INTERVAL_SECONDS,
        retry_delay: float = RETRY_DELAY_SECONDS,
        clock: Callable[[], float] = time.monotonic,
        decoder: Decoder = decode_to_wav16k,
        splitter: Splitter = split_wav,
    ) -> None:
        self.cfg = cfg
        self.store = store or InboxStore(cfg.inbox_root)
        self._lock = InboxLock(self.store.root)
        self._background = background
        # A one-shot pass attempts each item at most once; the live engine
        # instead retries a failed item after `retry_delay`.
        self._once_per_pass = not background
        self._on_event = on_event
        self._scan_interval = scan_interval
        self._retry_delay = retry_delay
        self._clock = clock
        self._decoder = decoder
        self._splitter = splitter
        self._prep: _Preparation | None = None
        self._active: _Active | None = None
        self._next_lock_try = float("-inf")
        self._next_scan = float("-inf")
        self._next_prune = float("-inf")
        self._dead_since: float | None = None
        self._attempted: set[str] = set()
        #: Ids of the items this processor started, in order.
        self.processed: list[str] = []

    # ------------------------------------------------------------------
    # Lock
    # ------------------------------------------------------------------

    @property
    def holds_lock(self) -> bool:
        return self._lock.held

    def try_acquire(self) -> bool:
        """Take the inbox lock if free. On success, requeue items a dead
        holder left ``processing`` and prune old ``done`` items."""
        if self._lock.held:
            return True
        try:
            acquired = self._lock.try_acquire()
        except OSError as exc:
            self._emit("warn", f"inbox: cannot open {self._lock.path}: {exc}")
            return False
        if acquired:
            self._recover_interrupted()
            self._prune()
        return acquired

    def release(self) -> None:
        """Requeue any in-progress item, then drop the lock."""
        if self._lock.held:
            self.abandon()
        self._lock.release()

    # ------------------------------------------------------------------
    # Incremental driving (live engine and the one-shot loop)
    # ------------------------------------------------------------------

    @property
    def busy(self) -> bool:
        return self._prep is not None or self._active is not None

    @property
    def inflight_job_id(self) -> str | None:
        return self._active.inflight if self._active is not None else None

    def poll(self, *, force: bool = False) -> list[dict[str, Any]]:
        """Advance the state machine; return ASR jobs ready to submit (≤ 1).

        Cheap when idle: the lock retry and the directory scan are each rate
        limited to ``scan_interval`` unless ``force``.
        """
        now = self._clock()
        if not self._lock.held:
            if not force and now < self._next_lock_try:
                return []
            self._next_lock_try = now + self._scan_interval
            if not self.try_acquire():
                return []
        if self._prep is not None:
            if not self._prep.done.is_set():
                return []
            self._finish_preparation()
        if self._active is not None:
            return self._next_job()
        if not force and now < self._next_scan:
            return []
        self._next_scan = now + self._scan_interval
        if now >= self._next_prune:
            self._prune()
        item = self.next_runnable()
        if item is None:
            return []
        self._start(item)
        if self._prep is not None and self._prep.done.is_set():
            self._finish_preparation()
        return self._next_job() if self._active is not None else []

    def mark_submitted(self, job_id: str) -> None:
        """The job left the caller's backlog for the worker."""
        a = self._active
        if a is not None and a.inflight == job_id:
            a.submitted = True
            self._dead_since = None

    def job_failed(self, job_id: str, error: str) -> bool:
        """The caller could not submit ``job_id``; fail its item."""
        a = self._active
        if a is None or a.inflight != job_id:
            return False
        self._fail(a.item, a.work_dir, error)
        return True

    def handle_result(self, result: dict[str, Any]) -> list[Path]:
        """Consume a worker result for an inbox job.

        Returns the transcripts it wrote, for the caller's post-write hooks.
        A stale result (its item was abandoned or already failed) is ignored.
        """
        a = self._active
        job_id = result.get("job_id")
        if a is None or job_id is None or job_id != a.inflight:
            return []
        a.inflight = None
        a.submitted = False
        self._dead_since = None
        seq = int(result.get("chunk_seq", 0) or 0)
        total = len(a.pieces)
        if not result.get("ok"):
            lines = str(result.get("error") or "").strip().splitlines()
            self._fail(a.item, a.work_dir, f"chunk {seq}/{total} failed: {lines[0] if lines else 'unknown error'}")
            return []
        written: list[Path] = []
        tp = result.get("transcript_path")
        if isinstance(tp, str) and tp:
            path = os.path.abspath(tp)
            a.transcripts.append(path)
            written.append(Path(path))
            self._emit("info", f"inbox: {a.item.label} — chunk {seq}/{total} → {Path(path).name}")
        else:
            self._emit("info", f"inbox: {a.item.label} — chunk {seq}/{total}: no speech")
        a.chunks_done += 1
        self.store.write_status(
            a.item, chunks_done=a.chunks_done, transcripts=list(a.transcripts)
        )
        if a.chunks_done >= total:
            self._complete()
        return written

    def check_worker(self, alive: bool) -> list[str]:
        """Detect a submitted job lost to a dead worker; fail its item.

        Returns the job ids given up on, so the caller can release whatever
        it holds for them (e.g. the Metal gate).
        """
        a = self._active
        if a is None or a.inflight is None or not a.submitted or alive:
            self._dead_since = None
            return []
        now = self._clock()
        if self._dead_since is None:
            self._dead_since = now
            return []
        if now - self._dead_since < LOST_WORKER_GRACE_SECONDS:
            return []
        lost = a.inflight
        self._fail(a.item, a.work_dir, "the transcription worker exited while transcribing this recording")
        return [lost]

    def abandon(self) -> None:
        """Stop work in progress and put its item back to ``queued``.

        Used on a graceful stop: the interrupted attempt is not counted, and
        the deterministic session id makes the next run rewrite the same
        transcripts.
        """
        prep, self._prep = self._prep, None
        if prep is not None:
            prep.cancel.set()
            if prep.thread is not None:
                prep.thread.join(timeout=5.0)
            self._requeue(prep.item, prep.prev_attempts, prep.work_dir)
        a, self._active = self._active, None
        if a is not None:
            self._requeue(a.item, a.prev_attempts, a.work_dir)
        self._dead_since = None

    def next_runnable(self) -> InboxItem | None:
        """Oldest item that is ``queued``, or ``failed`` with attempts left."""
        now = now_local()
        candidates: list[InboxItem] = []
        for item in self.store.items():
            if self._once_per_pass and item.id in self._attempted:
                continue
            if item.state == "queued":
                candidates.append(item)
            elif item.state == "failed" and item.attempts < MAX_ATTEMPTS:
                waited = (now - item.updated_at).total_seconds()
                if self._once_per_pass or waited >= self._retry_delay:
                    candidates.append(item)
        if not candidates:
            return None
        return min(candidates, key=lambda i: (i.added_at, i.id))

    # ------------------------------------------------------------------
    # One-shot driving (`huske inbox process`)
    # ------------------------------------------------------------------

    def run_pending(
        self,
        worker_factory: Callable[[], AsrWorker],
        *,
        should_stop: Callable[[], bool] | None = None,
        poll_timeout: float = 0.25,
    ) -> None:
        """Block until every runnable item has been attempted once.

        The caller holds the lock. The worker is created lazily, so a pass
        with nothing to do never loads a model.
        """
        worker: AsrWorker | None = None
        try:
            while True:
                if should_stop is not None and should_stop():
                    self.abandon()
                    return
                for job in self.poll(force=True):
                    job_id = str(job["job_id"])
                    try:
                        if worker is None:
                            worker = worker_factory()
                            worker.start()
                        worker.submit(job)
                    except Exception as exc:
                        self.job_failed(job_id, f"transcription worker failed to start: {exc}")
                        continue
                    self.mark_submitted(job_id)
                if not self.busy:
                    if self.next_runnable() is None:
                        return
                    continue
                if worker is None or self.inflight_job_id is None:
                    continue
                result = worker.poll_result(timeout=poll_timeout)
                if result is not None and is_inbox_job_id(result.get("job_id")):
                    self.handle_result(result)
                self.check_worker(worker.alive)
        finally:
            if worker is not None:
                worker.stop(drain_timeout=5.0)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _emit(self, severity: str, message: str) -> None:
        if self._on_event is not None:
            try:
                self._on_event(severity, message)
            except Exception:
                pass

    def _start(self, item: InboxItem) -> None:
        prev = item.attempts
        started = item.started_at.astimezone()
        work_dir = item.dir / WORK_DIR
        shutil.rmtree(work_dir, ignore_errors=True)
        self._attempted.add(item.id)
        if item.id not in self.processed:
            self.processed.append(item.id)
        self.store.write_status(
            item,
            state="processing",
            attempts=prev + 1,
            chunks_total=0,
            chunks_done=0,
            session_id=session_id_for(item.id, started),
            transcripts=[],
            error=None,
        )
        self._emit("info", f"inbox: preparing {item.label}")
        prep = _Preparation(
            item,
            work_dir=work_dir,
            max_seconds=self.cfg.chunk_seconds,
            prev_attempts=prev,
            decoder=self._decoder,
            splitter=self._splitter,
        )
        self._prep = prep
        if self._background:
            prep.thread = threading.Thread(
                target=prep.run, name="huske-inbox-prepare", daemon=True
            )
            prep.thread.start()
        else:
            prep.run()

    def _finish_preparation(self) -> None:
        prep, self._prep = self._prep, None
        if prep is None or prep.cancelled:
            return
        item = prep.item
        if prep.error is not None:
            self._fail(item, prep.work_dir, f"could not decode: {prep.error}")
            return
        started = item.started_at.astimezone()
        self._active = _Active(
            item=item,
            session_id=session_id_for(item.id, started),
            started_at=started,
            work_dir=prep.work_dir,
            pieces=list(prep.pieces),
            prev_attempts=prep.prev_attempts,
        )
        if not prep.pieces:
            self._emit("info", f"inbox: {item.label} has no audio")
            self._complete()
            return
        self.store.write_status(item, chunks_total=len(prep.pieces))
        minutes = prep.duration_seconds / 60.0
        self._emit(
            "info",
            f"inbox: transcribing {item.label} ({minutes:.1f} min, "
            f"{len(prep.pieces)} chunk(s))",
        )

    def _next_job(self) -> list[dict[str, Any]]:
        a = self._active
        if a is None or a.inflight is not None:
            return []
        if a.next_index >= len(a.pieces):
            self._complete()
            return []
        piece, path = a.pieces[a.next_index]
        a.next_index += 1
        job_id = f"{JOB_ID_PREFIX}{a.item.id}:{piece.seq}"
        a.inflight = job_id
        a.submitted = False
        self._dead_since = None
        return [self._job(a, piece, path, job_id)]

    def _job(self, a: _Active, piece: Piece, path: Path, job_id: str) -> dict[str, Any]:
        cfg = self.cfg
        start = a.started_at + timedelta(seconds=piece.offset_seconds)
        end = start + timedelta(seconds=piece.duration_seconds)
        rec = a.item.recording
        extra_raw = {
            "origin": rec.get("origin") or "file",
            "device": rec.get("device"),
            "title": rec.get("title"),
            "import_id": a.item.id,
        }
        extra = {k: v for k, v in extra_raw.items() if isinstance(v, str) and v}
        return {
            "job_id": job_id,
            "chunk_seq": piece.seq,
            "session_id": a.session_id,
            "audio_paths": {"microphone": str(path)},
            "start_time": start.isoformat(),
            "end_time": end.isoformat(),
            "expected_duration_seconds": piece.duration_seconds,
            "actual_duration_seconds": piece.duration_seconds,
            "gap_seconds": 0.0,
            "audio_sources": ["microphone"],
            "incomplete": False,
            "output_root": str(cfg.output_root),
            "asr_engine": cfg.asr_engine,
            "config_model": cfg.model,
            "parakeet_model": cfg.parakeet_model,
            "config_compute_type": cfg.compute_type,
            "config_device": cfg.device,
            "language": cfg.language,
            # One source, no far-end reference: echo handling does not apply.
            "echo_cancel": False,
            "echo_dedup": "off",
            # Piece WAVs are scratch; the original's retention is decided here.
            "keep_audio": False,
            "keep_audio_format": "wav",
            "whisper_idle_unload": cfg.whisper_idle_unload,
            "whisper_idle_unload_seconds": cfg.whisper_idle_unload_seconds,
            "overwrite": True,
            "extra_frontmatter": extra,
        }

    def _complete(self) -> None:
        a, self._active = self._active, None
        if a is None:
            return
        item = a.item
        total = len(a.pieces)
        # Record `done` before touching the audio: a crash in between then
        # leaves a finished item with leftover audio (pruned later), never a
        # half-finished item whose audio is already gone.
        self.store.write_status(
            item,
            state="done",
            chunks_total=total,
            chunks_done=total,
            transcripts=list(a.transcripts),
            error=None,
        )
        try:
            self._retain_audio(item, a.started_at)
        except OSError as exc:
            self._emit("warn", f"inbox: {item.label}: could not clean up audio: {exc}")
        shutil.rmtree(a.work_dir, ignore_errors=True)
        self._emit(
            "info", f"inbox: {item.label} done → {len(a.transcripts)} transcript(s)"
        )
        self._next_scan = float("-inf")  # pick up the next item right away

    def _retain_audio(self, item: InboxItem, started_at: datetime) -> Path | None:
        audio = item.audio_path
        if not audio.is_file():
            return None
        if not self.cfg.keep_audio:
            audio.unlink()
            return None
        dest_dir = paths.imported_audio_dir(self.cfg, started_at)
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / f"{item.id}{audio.suffix}"
        shutil.move(str(audio), str(dest))
        return dest

    def _fail(self, item: InboxItem, work_dir: Path, error: str) -> None:
        if self._active is not None and self._active.item.id == item.id:
            self._active = None
        shutil.rmtree(work_dir, ignore_errors=True)
        self.store.write_status(item, state="failed", error=error)
        attempts = item.attempts
        if attempts >= MAX_ATTEMPTS:
            self._emit(
                "error",
                f"inbox: {item.label} failed — giving up after {attempts} attempts: {error}",
            )
        else:
            self._emit(
                "warn",
                f"inbox: {item.label} failed (attempt {attempts}/{MAX_ATTEMPTS}): {error}",
            )
        self._next_scan = float("-inf")

    def _requeue(self, item: InboxItem, prev_attempts: int, work_dir: Path) -> None:
        shutil.rmtree(work_dir, ignore_errors=True)
        try:
            self.store.write_status(
                item,
                state="queued",
                attempts=prev_attempts,
                chunks_total=0,
                chunks_done=0,
                transcripts=[],
                error=None,
            )
        except OSError:
            pass

    def _recover_interrupted(self) -> None:
        """Items left ``processing`` by a holder that died: requeue them.

        The interrupted attempt counts, so a recording that crashes the
        transcriber every time still stops after ``MAX_ATTEMPTS``.
        """
        for item in self.store.items():
            if item.state != "processing":
                continue
            shutil.rmtree(item.dir / WORK_DIR, ignore_errors=True)
            if item.attempts >= MAX_ATTEMPTS:
                self.store.write_status(
                    item,
                    state="failed",
                    error=f"interrupted while transcribing; gave up after {item.attempts} attempts",
                )
            else:
                self.store.write_status(
                    item, state="queued", chunks_done=0, transcripts=[], error=None
                )

    def _prune(self) -> None:
        self._next_prune = self._clock() + PRUNE_INTERVAL_SECONDS
        # A crash between writing `done` and cleaning up leaves the audio
        # behind: apply the retention policy to it now.
        for item in self.store.items():
            if item.state == "done" and item.audio_path.is_file():
                try:
                    self._retain_audio(item, item.started_at)
                except OSError:
                    pass
        try:
            pruned = self.store.prune()
        except OSError:
            return
        if pruned:
            self._emit("info", f"inbox: pruned {len(pruned)} finished item(s) older than 30 days")
