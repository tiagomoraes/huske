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

A piece that fails does not stop the others: the attempt goes on, the item
ends ``failed`` with ``missing_chunks`` naming the pieces without a result,
and the transcripts of the finished ones stay listed (Huske.app hands them to
the phone as a partial transcript). What is finished is remembered in
``chunk_results``, so every later attempt — automatic, after a re-queue, or
``huske inbox retry`` — transcribes only the missing pieces.

Each piece's job carries a string ``job_id`` (``inbox:<id>:<seq>``) that the
worker echoes back; results are matched on it, never on ``chunk_seq``, which
restarts at 1 for every imported recording and so collides with live chunks.
"""

from __future__ import annotations

import hashlib
import json
import math
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
    THROUGHPUT_FILE,
    WORK_DIR,
    InboxItem,
    InboxLock,
    InboxStore,
    now_local,
    session_id_for,
)
from huske.languages import normalize_language
from huske.transcribe.worker import asr_job_fields

JOB_ID_PREFIX = "inbox:"
SCAN_INTERVAL_SECONDS = 5.0
# The live engine waits this long after a failure before retrying the item.
RETRY_DELAY_SECONDS = 60.0
# A submitted job whose worker has been dead this long is considered lost.
LOST_WORKER_GRACE_SECONDS = 3.0
PRUNE_INTERVAL_SECONDS = 3600.0
# How often `chunk_progress` of the piece in flight is refreshed in status.json.
PROGRESS_INTERVAL_SECONDS = 5.0
# A piece shorter than this is mostly fixed cost (model load); it says little
# about how long a long one takes, so it does not feed the measured speed.
MIN_MEASURED_AUDIO_SECONDS = 30.0

EventSink = Callable[[str, str], None]
Decoder = Callable[..., float]
Splitter = Callable[..., list[tuple[Piece, Path]]]


def is_inbox_job_id(value: object) -> bool:
    """True for a ``job_id`` minted by the inbox (never set on live chunks)."""
    return isinstance(value, str) and value.startswith(JOB_ID_PREFIX)


def split_key(cfg: RuntimeConfig, pieces: list[tuple[Piece, Path]]) -> str:
    """Names one way of cutting a recording, and the ASR settings used on it.

    Finished pieces are only reused by a later attempt when this is unchanged:
    a different ``chunk_minutes`` moves the cuts (piece 2 is other audio), and
    a different engine, model or language would leave one transcript written
    two ways.
    """
    model = cfg.parakeet_model if cfg.asr_engine == "parakeet" else cfg.model
    payload = json.dumps(
        {
            "asr": [cfg.asr_engine, model, cfg.language],
            "pieces": [[p.seq, p.start_frame, p.end_frame, p.sample_rate] for p, _ in pieces],
        },
        sort_keys=True,
    )
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:16]


def finished_chunks(
    status: dict[str, Any], *, key: str | None = None
) -> tuple[int, dict[int, str | None]]:
    """``(total, {piece number: transcript path or None})`` from ``chunk_results``.

    The pieces an earlier attempt finished, as far as they still hold: a piece
    whose transcript file is gone counts as not done. With ``key``, nothing
    is returned unless the recording was cut the same way. ``(0, {})`` when
    there is no usable record.
    """
    record = status.get("chunk_results")
    if not isinstance(record, dict):
        return 0, {}
    if key is not None and record.get("split") != key:
        return 0, {}
    total = record.get("total")
    done = record.get("done")
    if not isinstance(total, int) or isinstance(total, bool) or total <= 0:
        return 0, {}
    if not isinstance(done, dict):
        return 0, {}
    results: dict[int, str | None] = {}
    for raw_seq, path in done.items():
        try:
            seq = int(raw_seq)
        except (TypeError, ValueError):
            continue
        if not 1 <= seq <= total:
            continue
        if path is None:
            results[seq] = None  # transcribed, no speech
        elif isinstance(path, str) and path and os.path.isfile(path):
            results[seq] = path
    return total, results


def partial_fields(total: int, results: dict[int, str | None]) -> dict[str, Any]:
    """Status fields of an item that stopped with ``results`` of ``total`` pieces."""
    return {
        "chunks_total": total,
        "chunks_done": len(results),
        "transcripts": [path for _, path in sorted(results.items()) if path],
        "missing_chunks": [seq for seq in range(1, total + 1) if seq not in results],
    }


def estimate_piece_progress(elapsed_seconds: float, expected_seconds: float) -> float | None:
    """How far through the piece in flight the transcriber probably is (0 to 1).

    An estimate from elapsed time, for a status line that would otherwise sit
    on "1 of 3" for minutes: the ASR call is opaque (``mlx_whisper`` reports
    no progress) so there is nothing real to read. Rises steadily to 0.9 at
    the expected duration; past it, creeps towards 0.99 and stays there. It
    only ever grows with time and never says "done": that is the piece's
    result arriving, which moves ``chunks_done`` instead.
    """
    if expected_seconds <= 0 or elapsed_seconds < 0:
        return None
    ratio = elapsed_seconds / expected_seconds
    if ratio <= 1.0:
        return 0.9 * ratio
    return 0.9 + 0.09 * (1.0 - math.exp(-(ratio - 1.0)))


class Throughput:
    """Measured transcription speed on this Mac, per ASR engine and model.

    Wall seconds per second of audio, from pieces this inbox has actually
    transcribed — never an assumed figure. Kept in ``<inbox_root>/
    .throughput.json`` so the first piece of a later pass has it too; until
    one piece has been measured there is no estimate at all. Recent pieces
    weigh more (each new one halves the weight of what came before). Only the
    inbox lock holder writes it.
    """

    def __init__(self, path: Path, key: str) -> None:
        self._path = path
        self._key = key
        self._loaded = False
        self._wall = 0.0
        self._audio = 0.0

    def _load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
            entry = data["engines"][self._key]
            wall = float(entry["wall_seconds"])
            audio = float(entry["audio_seconds"])
        except (OSError, ValueError, KeyError, TypeError):
            return
        if math.isfinite(wall) and math.isfinite(audio) and wall > 0 and audio > 0:
            self._wall, self._audio = wall, audio

    def rate(self) -> float | None:
        """Wall seconds per audio second, or None when nothing was measured."""
        self._load()
        if self._audio <= 0 or self._wall <= 0:
            return None
        return self._wall / self._audio

    def record(self, wall_seconds: float, audio_seconds: float) -> None:
        if audio_seconds < MIN_MEASURED_AUDIO_SECONDS or wall_seconds <= 0:
            return
        self._load()
        self._wall = self._wall * 0.5 + wall_seconds
        self._audio = self._audio * 0.5 + audio_seconds
        try:
            try:
                data = json.loads(self._path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                data = {}
            if not isinstance(data, dict) or not isinstance(data.get("engines"), dict):
                data = {"version": 1, "engines": {}}
            data["engines"][self._key] = {
                "wall_seconds": round(self._wall, 3),
                "audio_seconds": round(self._audio, 3),
            }
            tmp = self._path.with_name(f"{self._path.name}.{os.getpid()}.tmp")
            tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            os.replace(tmp, self._path)
        except OSError:
            pass  # an estimate is never worth failing a transcription for


# How often a one-shot pass looks for a live session to yield to.
LIVE_SESSION_CHECK_SECONDS = 1.0


def live_session_running(cfg: RuntimeConfig) -> bool:
    """True while a ``huske run`` session holds a live lock under ``audio_root``.

    The live engine writes ``audio_root/<session>/.lock`` (its pid) before it
    first tries the inbox lock, so a one-shot pass sees a starting session at
    once. A lock naming a dead process (a crashed session) does not count.
    """
    from huske.session import is_lock_alive

    try:
        entries = list(os.scandir(cfg.audio_root))
    except OSError:
        return False
    for entry in entries:
        if entry.name in {"incomplete", "imported"}:
            continue
        try:
            if not entry.is_dir():
                continue
        except OSError:
            continue
        lock = paths.lock_path(Path(entry.path))
        if lock.is_file() and is_lock_alive(lock):
            return True
    return False


class LiveSessionWatch:
    """``should_stop`` for a one-shot pass: a live session has started.

    Checks at most every ``interval`` seconds and stays tripped once it fires.
    """

    def __init__(
        self,
        cfg: RuntimeConfig,
        *,
        interval: float = LIVE_SESSION_CHECK_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._cfg = cfg
        self._interval = interval
        self._clock = clock
        self._next = float("-inf")
        self.tripped = False

    def __call__(self) -> bool:
        if self.tripped:
            return True
        now = self._clock()
        if now < self._next:
            return False
        self._next = now + self._interval
        self.tripped = live_session_running(self._cfg)
        return self.tripped


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
    # How this recording was cut (`split_key`), for `chunk_results`.
    key: str = ""
    next_index: int = 0
    inflight: str | None = None
    inflight_seq: int = 0
    submitted: bool = False
    # Finished pieces, by number: the transcript each wrote (None: no speech).
    # Starts with what earlier attempts finished.
    results: dict[int, str | None] = field(default_factory=dict)
    # Pieces that failed in this attempt, by number: the first line of why.
    failed: dict[int, str] = field(default_factory=dict)
    # The piece in flight, for the `chunk_progress` estimate.
    inflight_seconds: float = 0.0
    submitted_at: float | None = None
    progress: float = 0.0
    next_progress_at: float = float("-inf")

    @property
    def chunks_done(self) -> int:
        return len(self.results)

    @property
    def transcripts(self) -> list[str]:
        """Transcripts written so far, in chronological (piece) order."""
        return [path for _, path in sorted(self.results.items()) if path]


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
        # `run_pending`'s stop request (SIGTERM, a live session starting),
        # while it runs: lets a preparation cut short by the stop be told
        # apart from one that failed.
        self._should_stop: Callable[[], bool] | None = None
        model = cfg.parakeet_model if cfg.asr_engine == "parakeet" else cfg.model
        self._throughput = Throughput(
            self.store.root / THROUGHPUT_FILE, f"{cfg.asr_engine}:{model}"
        )
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
            self._refresh_progress(now)
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
            a.submitted_at = self._clock()
            a.next_progress_at = a.submitted_at + PROGRESS_INTERVAL_SECONDS
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
        submitted_at, a.submitted_at = a.submitted_at, None
        self._dead_since = None
        seq = a.inflight_seq
        total = len(a.pieces)
        if not result.get("ok"):
            # This piece has no transcript; the others may still get one. The
            # attempt goes on and ends `failed` with this piece missing.
            lines = str(result.get("error") or "").strip().splitlines()
            a.failed[seq] = lines[0] if lines else "unknown error"
            self._emit(
                "warn", f"inbox: {a.item.label} — chunk {seq}/{total} failed: {a.failed[seq]}"
            )
            if not self._pieces_left(a):
                self._finish()
            else:
                # Nothing new to record, but the estimate for this piece must
                # not sit on the next one (a status write drops it).
                self._write_progress(a)
            return []
        written: list[Path] = []
        tp = result.get("transcript_path")
        if isinstance(tp, str) and tp:
            path = os.path.abspath(tp)
            a.results[seq] = path
            written.append(Path(path))
            self._emit("info", f"inbox: {a.item.label} — chunk {seq}/{total} → {Path(path).name}")
            # Speech was transcribed: a fair sample of this Mac's speed. (A
            # silent piece returns at once and would flatter it.)
            if submitted_at is not None:
                self._throughput.record(self._clock() - submitted_at, a.inflight_seconds)
        else:
            a.results[seq] = None
            self._emit("info", f"inbox: {a.item.label} — chunk {seq}/{total}: no speech")
        self._write_progress(a)
        if not self._pieces_left(a):
            self._finish()
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

        Used on a graceful stop: the interrupted attempt is not counted. The
        pieces it finished stay recorded (``chunk_results``), so the next run
        goes on from there; the piece in flight is transcribed again, into
        the same file (the session id is deterministic).
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
        self._should_stop = should_stop
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
            self._should_stop = None
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
            if self._should_stop is not None and self._should_stop():
                # Asked to stop while decoding. SIGTERM goes to the whole
                # process group, so it took `afconvert` down as well, and that
                # reads as a decode error: it is the stop, not the recording.
                # Back to the queue, the attempt unspent.
                self._requeue(item, prep.prev_attempts, prep.work_dir)
                return
            self._fail(item, prep.work_dir, f"could not decode: {prep.error}")
            return
        started = item.started_at.astimezone()
        pieces = list(prep.pieces)
        key = split_key(self.cfg, pieces)
        # What earlier attempts finished, if the recording is cut the same way
        # and their transcripts are still there: not transcribed again.
        _, results = finished_chunks(item.status, key=key)
        results = {seq: path for seq, path in results.items() if seq <= len(pieces)}
        a = _Active(
            item=item,
            session_id=session_id_for(item.id, started),
            started_at=started,
            work_dir=prep.work_dir,
            pieces=pieces,
            prev_attempts=prep.prev_attempts,
            key=key,
            results=results,
        )
        self._active = a
        if not pieces:
            self._emit("info", f"inbox: {item.label} has no audio")
            self._complete()
            return
        self._write_progress(a)
        minutes = prep.duration_seconds / 60.0
        kept = f", {len(results)} already transcribed" if results else ""
        self._emit(
            "info",
            f"inbox: transcribing {item.label} ({minutes:.1f} min, "
            f"{len(pieces)} chunk(s){kept})",
        )

    def _next_job(self) -> list[dict[str, Any]]:
        a = self._active
        if a is None or a.inflight is not None:
            return []
        if not self._pieces_left(a):
            self._finish()
            return []
        piece, path = a.pieces[a.next_index]
        a.next_index += 1
        job_id = f"{JOB_ID_PREFIX}{a.item.id}:{piece.seq}"
        a.inflight = job_id
        a.inflight_seq = piece.seq
        a.submitted = False
        a.inflight_seconds = float(piece.duration_seconds)
        a.submitted_at = None
        a.progress = 0.0
        self._dead_since = None
        return [self._job(a, piece, path, job_id)]

    @staticmethod
    def _pieces_left(a: _Active) -> bool:
        """Move past the pieces that already have a result; is one left?"""
        while a.next_index < len(a.pieces) and a.pieces[a.next_index][0].seq in a.results:
            a.next_index += 1
        return a.next_index < len(a.pieces)

    def _finish(self) -> None:
        """Every piece was attempted: `done`, or `failed` with what is missing."""
        a = self._active
        if a is None:
            return
        if not a.failed:
            self._complete()
            return
        total = len(a.pieces)
        seqs = sorted(a.failed)
        why = a.failed[seqs[0]]
        if len(seqs) == 1:
            error = f"chunk {seqs[0]}/{total} failed: {why}"
        else:
            error = f"chunks {', '.join(str(s) for s in seqs)} of {total} failed: {why}"
        self._fail(a.item, a.work_dir, error)

    def _write_progress(self, a: _Active) -> None:
        """Record the finished pieces: the counts Huske.app shows, and
        ``chunk_results`` for a later attempt to pick up from."""
        self.store.write_status(
            a.item,
            chunks_total=len(a.pieces),
            chunks_done=a.chunks_done,
            transcripts=a.transcripts,
            chunk_results={
                "split": a.key,
                "total": len(a.pieces),
                "done": {str(seq): path for seq, path in sorted(a.results.items())},
            },
        )

    def _refresh_progress(self, now: float) -> None:
        """Publish ``chunk_progress`` for the piece being transcribed.

        At most every ``PROGRESS_INTERVAL_SECONDS``, only once this Mac's
        speed has been measured, and only forwards.
        """
        a = self._active
        if a is None or a.inflight is None or not a.submitted or a.submitted_at is None:
            return
        if now < a.next_progress_at:
            return
        a.next_progress_at = now + PROGRESS_INTERVAL_SECONDS
        rate = self._throughput.rate()
        if rate is None:
            return
        estimate = estimate_piece_progress(now - a.submitted_at, a.inflight_seconds * rate)
        if estimate is None:
            return
        fraction = math.floor(estimate * 100) / 100
        if fraction <= a.progress:
            return
        a.progress = fraction
        try:
            self.store.write_status(a.item, chunk_progress=fraction)
        except OSError:
            pass

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
        language = cfg.language
        if rec.get("language"):
            try:
                language = normalize_language(rec.get("language")) or cfg.language
            except ValueError:
                language = cfg.language  # producer-written; never fail the item on it
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
            **asr_job_fields(cfg),
            "language": language,
            "config_compute_type": cfg.compute_type,
            "config_device": cfg.device,
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
            transcripts=a.transcripts,
            error=None,
            chunk_results=None,
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
        a = self._active
        if a is not None and a.item.id == item.id:
            self._active = None
        else:
            a = None
        shutil.rmtree(work_dir, ignore_errors=True)
        self.store.write_status(
            item, state="failed", error=error, **self._partial(item, a)
        )
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

    @staticmethod
    def _partial(item: InboxItem, a: _Active | None) -> dict[str, Any]:
        """What a failing item keeps: its finished pieces and which are missing.

        From the attempt itself when it got as far as cutting the recording;
        otherwise (it could not be decoded this time, or its holder died) from
        what earlier attempts recorded. Nothing when it was never cut.
        """
        if a is not None and a.pieces:
            return partial_fields(len(a.pieces), a.results)
        total, results = finished_chunks(item.status)
        return partial_fields(total, results) if total else {}

    def _requeue(self, item: InboxItem, prev_attempts: int, work_dir: Path) -> None:
        # `chunk_results` stays: the pieces already transcribed are not done
        # again by whoever picks the item up.
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
                    **self._partial(item, None),
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
