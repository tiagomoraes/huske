"""Embedding worker subprocess.

Why a subprocess? The same reason the transcription worker is one: embedding is
heavy, Metal-contending compute, and must not run in the recording process or
it would starve the audio drainer (see docs/adr/0003-embed-worker-isolation.md).
``huske run`` feeds finalized transcript paths here; the worker windows, embeds,
and upserts them off the hot path.

The worker is fed *paths to written ``.md`` files*, so it shares one code path
with the ``huske index`` backfill. It is started non-blocking — capture does not
wait on the embedding model to load; submissions queue until the worker is
ready, and an init failure degrades to "recording continues, no indexing".
"""

from __future__ import annotations

import multiprocessing as mp
import queue
import signal
import traceback
from typing import Any

# Spawn (not fork) keeps the parent's PortAudio / Core Audio state out of the
# child, matching the transcription worker.
_ctx = mp.get_context("spawn")

_SENTINEL = "__STOP__"


def _embed_worker_main(in_q: Any, out_q: Any, db_path: str, model_id: str) -> None:
    """Subprocess entry point: load embedder + store, then index submitted paths."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)

    from pathlib import Path as _Path

    try:
        from huske.search.embedder import build_embedder
        from huske.search.indexer import Indexer
        from huske.search.store import PassageStore

        embedder = build_embedder(model_id)
        store = PassageStore.open(_Path(db_path), embedding_model=model_id, dim=embedder.dim)
        indexer = Indexer(store, embedder)
    except Exception as exc:
        out_q.put({"ready": False, "error": f"{exc}\n{traceback.format_exc()}"})
        return

    out_q.put({"ready": True})

    while True:
        msg = in_q.get()
        if msg == _SENTINEL:
            store.close()
            return
        if not isinstance(msg, str):
            continue
        try:
            n = indexer.index_file(_Path(msg))
            out_q.put({"path": msg, "ok": True, "passages": n, "error": None})
        except Exception as exc:
            out_q.put(
                {
                    "path": msg,
                    "ok": False,
                    "passages": 0,
                    "error": f"{exc}\n{traceback.format_exc()}",
                }
            )


class EmbedWorker:
    """Manages the embedding subprocess + path/result queues."""

    SENTINEL = _SENTINEL

    def __init__(self, db_path: str, model_id: str) -> None:
        self._db_path = db_path
        self._model_id = model_id
        self._in_q: Any = _ctx.Queue()
        self._out_q: Any = _ctx.Queue()
        self._proc: Any = None

    def start(self) -> None:
        if self._proc is not None and self._proc.is_alive():
            return
        self._proc = _ctx.Process(
            target=_embed_worker_main,
            args=(self._in_q, self._out_q, self._db_path, self._model_id),
            name="huske-embed-worker",
        )
        self._proc.start()

    def submit(self, transcript_path: str) -> None:
        try:
            self._in_q.put(transcript_path)
        except (ValueError, OSError):
            pass

    def poll_result(self, timeout: float = 0.0) -> dict[str, Any] | None:
        try:
            msg = self._out_q.get(timeout=timeout)
        except queue.Empty:
            return None
        return msg if isinstance(msg, dict) else None

    def stop(self, drain_timeout: float = 5.0) -> None:
        if self._proc is None:
            return
        try:
            self._in_q.put(_SENTINEL)
        except (ValueError, OSError):
            pass
        self._proc.join(timeout=drain_timeout)
        if self._proc.is_alive():
            self._proc.terminate()
            self._proc.join(timeout=2.0)
            if self._proc.is_alive():
                self._proc.kill()
                self._proc.join(timeout=2.0)
        self._proc = None
        self._close_queues()

    def _close_queues(self) -> None:
        for q in (self._in_q, self._out_q):
            try:
                while True:
                    q.get_nowait()
            except (queue.Empty, OSError, EOFError, ValueError):
                pass
            try:
                q.cancel_join_thread()
            except Exception:
                pass
            try:
                q.close()
            except Exception:
                pass

    @property
    def alive(self) -> bool:
        return self._proc is not None and self._proc.is_alive()
