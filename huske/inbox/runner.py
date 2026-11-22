"""`huske inbox add|process|status` and `huske import` — the CLI side.

Every command prints exactly one JSON object on stdout under ``--json`` (the
shape Huske.app parses); human progress goes to stderr. Exit codes: 0 success
(including "deferred to the live engine"), 1 validation/usage errors, 2 when
processing ran and an item failed.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import signal
import sys
from collections.abc import Callable, Iterator
from pathlib import Path
from types import FrameType
from typing import Any

from huske.config import RuntimeConfig, load_config
from huske.inbox.processor import AsrWorker, InboxProcessor, LiveSessionWatch
from huske.inbox.store import InboxError, InboxItem, InboxStore, parse_timestamp

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_FAILED = 2
# A pass asked to stop with SIGTERM: the shell convention, 128 + 15.
EXIT_TERMINATED = 128 + int(signal.SIGTERM)


def _out(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, indent=2, ensure_ascii=False), flush=True)


def _err(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def _load(config_path: Path | None, json_output: bool) -> RuntimeConfig | None:
    try:
        return load_config(config_path=config_path)
    except ValueError as exc:
        if json_output:
            _out({"error": f"config: {exc}"})
        else:
            _err(f"[error] config: {exc}")
        return None


def make_worker(cfg: RuntimeConfig) -> AsrWorker:
    """The real ASR subprocess (tests replace this with an in-process fake)."""
    from huske.transcribe.worker import TranscriptionWorker

    return TranscriptionWorker(
        metal_cache_limit_mb=cfg.metal_cache_limit_mb,
        metal_memory_limit_mb=cfg.metal_memory_limit_mb,
        recycle_idle_process=cfg.recycle_idle_process,
    )


@contextlib.contextmanager
def _children_write_to_stderr() -> Iterator[None]:
    """Point fd 1 at stderr while child processes may run.

    The ASR subprocess and model downloaders inherit our stdout; anything they
    print there would corrupt the single JSON object Huske.app parses. Only
    rewires real file descriptors (a test runner's captured stdout is left
    alone).
    """
    try:
        sys.stdout.flush()
        fd = sys.stdout.fileno()
    except (AttributeError, OSError, ValueError, io.UnsupportedOperation):
        yield
        return
    saved = os.dup(fd)
    try:
        os.dup2(sys.stderr.fileno(), fd)
    except (OSError, ValueError, io.UnsupportedOperation):
        os.close(saved)
        yield
        return
    try:
        yield
    finally:
        with contextlib.suppress(Exception):
            sys.stdout.flush()
        os.dup2(saved, fd)
        os.close(saved)


def _status_line(item: dict[str, Any]) -> str:
    state = str(item.get("state", "?"))
    label = item.get("title") or item.get("source_filename") or ""
    total = int(item.get("chunks_total") or 0)
    progress = f"  {item.get('chunks_done', 0)}/{total}" if total else ""
    error = f"  — {item['error']}" if item.get("error") else ""
    return f"{state:<10} {item.get('id')}  {label}{progress}{error}"


# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------


def _add_one(
    store: InboxStore,
    file: Path,
    *,
    item_id: str | None,
    title: str | None,
    device: str | None,
    origin: str,
    started_at: str | None,
    duration: float | None,
    move: bool,
    language: str | None = None,
) -> tuple[InboxItem, bool]:
    when = parse_timestamp(started_at) if started_at else None
    return store.add(
        file,
        item_id=item_id,
        title=title,
        device=device,
        origin=origin,
        started_at=when,
        duration_seconds=duration,
        move=move,
        language=language,
    )


def run_inbox_add(
    file: Path,
    *,
    item_id: str | None = None,
    title: str | None = None,
    device: str | None = None,
    origin: str = "file",
    started_at: str | None = None,
    duration: float | None = None,
    move: bool = False,
    language: str | None = None,
    json_output: bool = False,
    config_path: Path | None = None,
) -> int:
    cfg = _load(config_path, json_output)
    if cfg is None:
        return EXIT_INVALID
    store = InboxStore(cfg.inbox_root)
    try:
        item, created = _add_one(
            store,
            file,
            item_id=item_id,
            title=title,
            device=device,
            origin=origin,
            started_at=started_at,
            duration=duration,
            move=move,
            language=language,
        )
    except (InboxError, OSError) as exc:
        if json_output:
            _out({"error": str(exc)})
        else:
            _err(f"[error] {exc}")
        return EXIT_INVALID
    payload = {**item.to_dict(), "created": created}
    if json_output:
        _out(payload)
    elif created:
        print(f"queued {item.id}  ({item.label})", flush=True)
    else:
        print(f"already in the inbox: {_status_line(payload)}", flush=True)
    return EXIT_OK


# ---------------------------------------------------------------------------
# process
# ---------------------------------------------------------------------------


class _TerminationWatch:
    """SIGTERM asks a one-shot pass to stop, the way a starting session does.

    Python's default for SIGTERM ends the process on the spot: no ``finally``
    runs. The item in progress stayed ``processing`` (and cost an attempt
    when the next lock holder recovered it), and the ASR worker was left
    transcribing for nobody. Huske.app's watchdog stops a pass with exactly
    this signal.

    The handler only raises a flag — nothing that takes a lock, since it runs
    between two bytecodes of the main thread. The pass polls the flag through
    the same ``should_stop`` hook as the live-session yield, so the stop is
    the ordinary one: the item goes back to ``queued`` with its attempt
    unspent and the worker is shut down.
    """

    def __init__(self) -> None:
        self.requested = False
        self._previous: Any = None
        self._installed = False

    def _handle(self, signum: int, frame: FrameType | None) -> None:
        self.requested = True

    def __enter__(self) -> _TerminationWatch:
        try:
            self._previous = signal.signal(signal.SIGTERM, self._handle)
            self._installed = True
        except ValueError:
            # Not the main thread (an embedding caller): signals are not ours.
            self._installed = False
        return self

    def __exit__(self, *exc: object) -> None:
        if self._installed:
            signal.signal(signal.SIGTERM, self._previous)
            self._installed = False


def _process(
    cfg: RuntimeConfig,
    *,
    json_output: bool,
    worker_factory: Callable[[RuntimeConfig], AsrWorker] | None = None,
) -> tuple[bool, list[InboxItem], bool]:
    """Transcribe every runnable item.

    Returns ``(deferred, items_processed, interrupted)``. ``deferred`` is True
    when another process (normally the live engine) holds the inbox lock and
    will transcribe the queue itself. ``interrupted`` is True when SIGTERM
    stopped the pass; the item it was on is back in ``queued``.
    """
    factory = worker_factory or make_worker

    def emit(severity: str, message: str) -> None:
        if not json_output:
            prefix = "" if severity == "info" else f"[{severity}] "
            _err(f"{prefix}{message}")

    processor = InboxProcessor(cfg, background=False, on_event=emit)
    # A live `huske run` transcribes the inbox with its own model: never keep
    # a second one loaded next to it. Yield as soon as a session starts; the
    # item in progress goes back to `queued` without spending its attempt.
    live_session = LiveSessionWatch(cfg)
    deferred = False
    interrupted = False
    with (
        _TerminationWatch() as terminate,
        _children_write_to_stderr() if json_output else contextlib.nullcontext(),
    ):

        def should_stop() -> bool:
            return terminate.requested or live_session()

        while True:
            if terminate.requested:
                interrupted = True
                break
            if live_session():
                emit("info", "inbox: a recording session is running; it will transcribe the inbox")
                deferred = True
                break
            if not processor.try_acquire():
                deferred = True
                break
            try:
                if processor.next_runnable() is not None:
                    from huske.output_readme import ensure_output_readme

                    cfg.output_root.mkdir(parents=True, exist_ok=True)
                    ensure_output_readme(cfg.output_root)
                processor.run_pending(lambda: factory(cfg), should_stop=should_stop)
            finally:
                processor.release()
            if terminate.requested:
                emit("info", "inbox: asked to stop; the recording in progress goes back to the queue")
                interrupted = True
                break
            if live_session.tripped:
                emit("info", "inbox: a recording session started; handing the inbox to it")
                deferred = True
                break
            # An item added after our last scan but before the release would
            # otherwise wait for the next engine start: look once more.
            if processor.next_runnable() is None:
                break
        items = [i for i in (processor.store.get(x) for x in processor.processed) if i]
        written = [p for i in items for p in i.status.get("transcripts") or []]
        # Asked to stop: no LLM clean-up and no network round trip on the way
        # out. The raw transcripts are already written; publishing catches up
        # on the next run.
        if written and cfg.distill_enabled and not interrupted:
            _clean_up(cfg, [Path(p) for p in written], emit)
        if written and cfg.sync_enabled and cfg.sync_remote and not interrupted:
            _publish(cfg, emit)
    return deferred, items, interrupted


def _clean_up(cfg: RuntimeConfig, paths: list[Path], emit: Callable[[str, str], None]) -> None:
    """Optional LLM post-processing of freshly written transcripts.

    The live engine does this in its background worker; a one-shot run does it
    here, after transcription and before publishing, so a phone recording gets
    the same treatment either way. Best-effort: a failure leaves the raw
    transcripts exactly as written and the run still succeeds.
    """
    from huske.distill.client import DistillError
    from huske.distill.distiller import build_distiller, distill_transcript
    from huske.distill.sidecar import write_sidecar

    try:
        corrector = build_distiller(cfg)
    except DistillError as exc:
        emit("warn", f"cleanup skipped, raw transcripts kept: {exc}")
        return
    try:
        cleaned = 0
        for path in paths:
            try:
                write_sidecar(path, distill_transcript(path, corrector))
                cleaned += 1
            except DistillError as exc:
                emit("warn", f"cleanup stopped, raw transcripts kept: {exc}")
                return
            except Exception as exc:  # one bad file must not stop the run
                emit("warn", f"cleanup failed for {path.name}: {exc}")
        if cleaned:
            emit("info", f"cleaned up {cleaned} transcript(s) with {corrector.label}")
    finally:
        corrector.close()


def _publish(cfg: RuntimeConfig, emit: Callable[[str, str], None]) -> None:
    """Best-effort Git publication of the new transcripts (never fails the run)."""
    try:
        from huske.sync.client import build_publisher

        result = build_publisher(cfg).sync()
    except Exception as exc:
        emit("warn", f"cloud sync: {exc}")
        return
    if result.changed:
        emit("info", f"cloud sync: published {result.changed} transcript(s)")


def run_inbox_process(
    *,
    json_output: bool = False,
    config_path: Path | None = None,
    worker_factory: Callable[[RuntimeConfig], AsrWorker] | None = None,
) -> int:
    cfg = _load(config_path, json_output)
    if cfg is None:
        return EXIT_INVALID
    deferred, items, interrupted = _process(
        cfg, json_output=json_output, worker_factory=worker_factory
    )
    failed = any(i.state == "failed" for i in items)
    # Whoever sent SIGTERM may have stopped reading: a closed pipe must not
    # turn a clean stop into a traceback.
    with contextlib.suppress(OSError) if interrupted else contextlib.nullcontext():
        if json_output:
            payload: dict[str, Any] = {
                "deferred_to_engine": deferred,
                "items": [i.to_dict() for i in items],
            }
            if interrupted:
                payload["interrupted"] = True
            _out(payload)
        else:
            if interrupted:
                print("stopped; the recording in progress is back in the queue", flush=True)
            elif deferred:
                print("the running huske engine holds the inbox and will transcribe it", flush=True)
            elif not items:
                print("nothing to transcribe", flush=True)
            for item in items:
                print(_status_line(item.to_dict()), flush=True)
                for path in item.status.get("transcripts") or []:
                    print(f"  {path}", flush=True)
    if interrupted:
        return EXIT_TERMINATED
    return EXIT_FAILED if failed else EXIT_OK


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------


def run_inbox_status(
    ids: list[str] | None = None,
    *,
    json_output: bool = False,
    config_path: Path | None = None,
) -> int:
    cfg = _load(config_path, json_output)
    if cfg is None:
        return EXIT_INVALID
    store = InboxStore(cfg.inbox_root)
    if ids:
        found: list[dict[str, Any]] = []
        for item_id in ids:
            item = store.get(item_id)
            found.append(item.to_dict() if item else {"id": item_id, "state": "unknown"})
        known = [d for d in found if d.get("state") != "unknown"]
        unknown = [d for d in found if d.get("state") == "unknown"]
        known.sort(key=lambda d: (str(d.get("added_at") or ""), str(d["id"])), reverse=True)
        records = known + unknown
    else:
        records = [i.to_dict() for i in store.list_newest_first()]
    if json_output:
        _out({"items": records})
    elif not records:
        print("the inbox is empty", flush=True)
    else:
        for record in records:
            print(_status_line(record), flush=True)
    return EXIT_OK


def run_inbox_retry(
    ids: list[str],
    *,
    json_output: bool = False,
    config_path: Path | None = None,
) -> int:
    """Re-queue failed items (resets their attempt count).

    The pieces a failed item already transcribed are kept (``chunk_results``
    is left alone): the new attempts only transcribe the missing ones.
    """
    cfg = _load(config_path, json_output)
    if cfg is None:
        return EXIT_INVALID
    store = InboxStore(cfg.inbox_root)
    records: list[dict[str, Any]] = []
    for item_id in ids:
        item = store.get(item_id)
        if item is None:
            records.append({"id": item_id, "state": "unknown", "retried": False})
            continue
        if item.state != "failed":
            records.append({**item.to_dict(), "retried": False})
            continue
        if not item.audio_path.exists():
            records.append(
                {**item.to_dict(), "retried": False, "error": "original audio is gone"}
            )
            continue
        store.write_status(
            item, state="queued", attempts=0, error=None, chunks_done=0, transcripts=[]
        )
        records.append({**item.to_dict(), "retried": True})
    if json_output:
        _out({"items": records})
    else:
        for record in records:
            mark = "re-queued" if record.get("retried") else f"not retried ({record.get('state')})"
            print(f"{record['id']}: {mark}", flush=True)
    return EXIT_OK if all(r.get("retried") for r in records) else EXIT_INVALID


# ---------------------------------------------------------------------------
# import
# ---------------------------------------------------------------------------


def run_import(
    files: list[Path],
    *,
    title: str | None = None,
    started_at: str | None = None,
    language: str | None = None,
    json_output: bool = False,
    config_path: Path | None = None,
    worker_factory: Callable[[RuntimeConfig], AsrWorker] | None = None,
) -> int:
    cfg = _load(config_path, json_output)
    if cfg is None:
        return EXIT_INVALID
    store = InboxStore(cfg.inbox_root)
    added: list[str] = []
    errors: list[dict[str, str]] = []
    for file in files:
        try:
            item, created = _add_one(
                store,
                file,
                item_id=None,
                title=title,
                device=None,
                origin="file",
                started_at=started_at,
                duration=None,
                move=False,
                language=language,
            )
        except (InboxError, OSError) as exc:
            errors.append({"file": str(file), "error": str(exc)})
            if not json_output:
                _err(f"[error] {file}: {exc}")
            continue
        added.append(item.id)
        if not json_output:
            verb = "queued" if created else "already imported"
            _err(f"{verb} {file.name} as {item.id}")

    deferred = False
    interrupted = False
    if added:
        deferred, _, interrupted = _process(
            cfg, json_output=json_output, worker_factory=worker_factory
        )
    finals = [i for i in (store.get(x) for x in added) if i]
    failed = any(i.state == "failed" for i in finals)

    with contextlib.suppress(OSError) if interrupted else contextlib.nullcontext():
        if json_output:
            payload: dict[str, Any] = {
                "deferred_to_engine": deferred,
                "items": [i.to_dict() for i in finals],
            }
            if errors:
                payload["errors"] = errors
            if interrupted:
                payload["interrupted"] = True
            _out(payload)
        else:
            if interrupted:
                print("stopped; the recording in progress is back in the queue", flush=True)
            elif deferred:
                print(
                    "queued — the running huske engine will transcribe the recording(s)",
                    flush=True,
                )
            for item in finals:
                print(_status_line(item.to_dict()), flush=True)
                for path in item.status.get("transcripts") or []:
                    print(f"  {path}", flush=True)
    if interrupted:
        return EXIT_TERMINATED
    if errors:
        return EXIT_INVALID
    return EXIT_FAILED if failed else EXIT_OK
