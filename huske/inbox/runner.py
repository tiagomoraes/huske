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
import sys
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

from huske.config import RuntimeConfig, load_config
from huske.inbox.processor import AsrWorker, InboxProcessor
from huske.inbox.store import InboxError, InboxItem, InboxStore, parse_timestamp

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_FAILED = 2


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


def _process(
    cfg: RuntimeConfig,
    *,
    json_output: bool,
    worker_factory: Callable[[RuntimeConfig], AsrWorker] | None = None,
) -> tuple[bool, list[InboxItem]]:
    """Transcribe every runnable item. Returns ``(deferred, items_processed)``.

    ``deferred`` is True when another process (normally the live engine)
    holds the inbox lock and will transcribe the queue itself.
    """
    factory = worker_factory or make_worker

    def emit(severity: str, message: str) -> None:
        if not json_output:
            prefix = "" if severity == "info" else f"[{severity}] "
            _err(f"{prefix}{message}")

    processor = InboxProcessor(cfg, background=False, on_event=emit)
    deferred = False
    with _children_write_to_stderr() if json_output else contextlib.nullcontext():
        while True:
            if not processor.try_acquire():
                deferred = True
                break
            try:
                if processor.next_runnable() is not None:
                    from huske.output_readme import ensure_output_readme

                    cfg.output_root.mkdir(parents=True, exist_ok=True)
                    ensure_output_readme(cfg.output_root)
                processor.run_pending(lambda: factory(cfg))
            finally:
                processor.release()
            # An item added after our last scan but before the release would
            # otherwise wait for the next engine start: look once more.
            if processor.next_runnable() is None:
                break
        items = [i for i in (processor.store.get(x) for x in processor.processed) if i]
        written = [p for i in items for p in i.status.get("transcripts") or []]
        if written and cfg.sync_enabled and cfg.sync_remote:
            _publish(cfg, emit)
    return deferred, items


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
    deferred, items = _process(cfg, json_output=json_output, worker_factory=worker_factory)
    failed = any(i.state == "failed" for i in items)
    if json_output:
        _out({"deferred_to_engine": deferred, "items": [i.to_dict() for i in items]})
    else:
        if deferred and not items:
            print("the running huske engine holds the inbox and will transcribe it", flush=True)
        elif not items:
            print("nothing to transcribe", flush=True)
        for item in items:
            print(_status_line(item.to_dict()), flush=True)
            for path in item.status.get("transcripts") or []:
                print(f"  {path}", flush=True)
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
    """Re-queue failed items (resets their attempt count)."""
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
    if added:
        deferred, _ = _process(cfg, json_output=json_output, worker_factory=worker_factory)
    finals = [i for i in (store.get(x) for x in added) if i]
    failed = any(i.state == "failed" for i in finals)

    if json_output:
        payload: dict[str, Any] = {
            "deferred_to_engine": deferred,
            "items": [i.to_dict() for i in finals],
        }
        if errors:
            payload["errors"] = errors
        _out(payload)
    else:
        if deferred:
            print("queued — the running huske engine will transcribe the recording(s)", flush=True)
        for item in finals:
            print(_status_line(item.to_dict()), flush=True)
            for path in item.status.get("transcripts") or []:
                print(f"  {path}", flush=True)
    if errors:
        return EXIT_INVALID
    return EXIT_FAILED if failed else EXIT_OK
