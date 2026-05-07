"""Transcription worker subprocess.

Why a subprocess? faster-whisper holds the GIL while doing CPU/Metal-bound
inference; running it in-process would starve the audio drainer thread.
"""

from __future__ import annotations

import multiprocessing as mp
import os
import queue
import sys
import traceback
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


# Use spawn on macOS to keep PortAudio out of the child.
_ctx = mp.get_context("spawn")


@dataclass
class TranscribeJob:
    chunk_seq: int
    session_id: str
    audio_path: str
    start_time: str  # ISO 8601
    end_time: str
    expected_duration_seconds: float
    actual_duration_seconds: float
    gap_seconds: float
    audio_sources: list[str]
    incomplete: bool
    output_root: str
    config_model: str
    config_compute_type: str
    config_device: str
    language: str | None
    keep_audio: bool


@dataclass
class TranscribeResult:
    chunk_seq: int
    ok: bool
    transcript_path: str | None
    error: str | None


_SENTINEL = "__STOP__"


def _worker_main(in_q: Any, out_q: Any) -> None:
    """Subprocess entry point. Loops on jobs until sentinel arrives."""
    # Defer heavy imports until inside the subprocess.
    from datetime import datetime as _dt
    from pathlib import Path as _Path

    from faster_whisper import WhisperModel

    from huske.config import RuntimeConfig
    from huske.paths import day_folder, transcript_filename
    from huske.models import AudioChunk
    from huske.transcribe.writer import (
        build_transcript_from_segments,
        write_transcript,
    )

    model: WhisperModel | None = None
    model_signature: tuple[str, str, str] | None = None

    while True:
        msg = in_q.get()
        if msg == _SENTINEL:
            return
        if not isinstance(msg, dict):
            continue
        job_data = msg
        try:
            sig = (
                job_data["config_model"],
                job_data["config_compute_type"],
                job_data["config_device"],
            )
            if model is None or sig != model_signature:
                device_arg = sig[2] if sig[2] != "auto" else "auto"
                # faster-whisper picks auto by inspecting hardware.
                model = WhisperModel(
                    sig[0],
                    compute_type=sig[1],
                    device="cpu" if device_arg == "cpu" else "auto",
                )
                model_signature = sig

            audio_path = job_data["audio_path"]
            language = job_data["language"]
            transcribe_kwargs: dict[str, Any] = {
                "beam_size": 5,
                "vad_filter": True,
            }
            if language:
                transcribe_kwargs["language"] = language

            segments_iter, info = model.transcribe(audio_path, **transcribe_kwargs)
            seg_list: list[dict] = []
            text_parts: list[str] = []
            for seg in segments_iter:
                text = seg.text.strip()
                seg_list.append(
                    {
                        "start": float(seg.start),
                        "end": float(seg.end),
                        "text": text,
                    }
                )
                text_parts.append(text)
            body = "\n\n".join(p for p in text_parts if p)

            start_time = _dt.fromisoformat(job_data["start_time"])
            end_time = _dt.fromisoformat(job_data["end_time"])

            transcript = build_transcript_from_segments(
                session_id=job_data["session_id"],
                chunk_seq=job_data["chunk_seq"],
                start_time=start_time,
                end_time=end_time,
                expected_duration_seconds=job_data["expected_duration_seconds"],
                actual_duration_seconds=job_data["actual_duration_seconds"],
                gap_seconds=job_data["gap_seconds"],
                audio_sources=job_data["audio_sources"],
                model=f"faster-whisper:{sig[0]}",
                language=info.language or "auto",
                incomplete=job_data["incomplete"],
                text=body,
                segments=seg_list or None,
            )

            # Build target path.
            output_root = _Path(job_data["output_root"])
            day = output_root / start_time.date().isoformat()
            day.mkdir(parents=True, exist_ok=True)
            chunk_proxy = AudioChunk(
                chunk_seq=transcript.chunk_seq,
                session_id=transcript.session_id,
                start_time=transcript.start_time,
                expected_duration_seconds=transcript.duration_seconds,
                audio_path=_Path(audio_path),
            )
            target = day / transcript_filename(chunk_proxy).name
            written = write_transcript(transcript, target)

            # Delete WAV if not keeping it.
            if not job_data.get("keep_audio", False):
                try:
                    _Path(audio_path).unlink(missing_ok=True)
                except OSError:
                    pass

            out_q.put(
                {
                    "chunk_seq": job_data["chunk_seq"],
                    "ok": True,
                    "transcript_path": str(written),
                    "error": None,
                }
            )
        except Exception as exc:  # noqa: BLE001
            tb = traceback.format_exc()
            out_q.put(
                {
                    "chunk_seq": job_data.get("chunk_seq", -1),
                    "ok": False,
                    "transcript_path": None,
                    "error": f"{exc}\n{tb}",
                }
            )


class TranscriptionWorker:
    """Manages the transcription subprocess + job/result queues."""

    SENTINEL = _SENTINEL

    def __init__(self) -> None:
        self._in_q: Any = _ctx.Queue()
        self._out_q: Any = _ctx.Queue()
        self._proc: Any = None

    def start(self) -> None:
        if self._proc is not None and self._proc.is_alive():
            return
        self._proc = _ctx.Process(
            target=_worker_main, args=(self._in_q, self._out_q), name="huske-worker"
        )
        self._proc.start()

    def submit(self, job: dict[str, Any]) -> None:
        self._in_q.put(job)

    def poll_result(self, timeout: float = 0.0) -> dict[str, Any] | None:
        try:
            return self._out_q.get(timeout=timeout)
        except queue.Empty:
            return None

    def stop(self, drain_timeout: float = 60.0) -> None:
        if self._proc is None:
            return
        try:
            self._in_q.put(_SENTINEL)
        except (ValueError, OSError):
            # Queue already closed — nothing to signal.
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
        # Drain leftovers and close both queues so the multiprocessing
        # resource_tracker doesn't warn about leaked semaphores at shutdown.
        # cancel_join_thread() abandons any unsent items in the feeder thread
        # — safe here because the worker process is gone.
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
    def queue_depth(self) -> int:
        # qsize is approximate but fine for UI display.
        try:
            return int(self._in_q.qsize())
        except (NotImplementedError, OSError):
            return 0

    @property
    def alive(self) -> bool:
        return self._proc is not None and self._proc.is_alive()


def chunk_to_job(
    chunk: Any,  # AudioChunk
    cfg: Any,  # RuntimeConfig
) -> dict[str, Any]:
    return {
        "chunk_seq": chunk.chunk_seq,
        "session_id": chunk.session_id,
        "audio_path": str(chunk.audio_path),
        "start_time": chunk.start_time.isoformat(),
        "end_time": (chunk.end_time or chunk.start_time).isoformat(),
        "expected_duration_seconds": float(chunk.expected_duration_seconds),
        "actual_duration_seconds": float(chunk.actual_duration_seconds or 0.0),
        "gap_seconds": float(chunk.gap_seconds),
        "audio_sources": list(chunk.audio_sources),
        "incomplete": bool(chunk.is_partial),
        "output_root": str(cfg.output_root),
        "config_model": cfg.model,
        "config_compute_type": cfg.compute_type,
        "config_device": cfg.device,
        "language": cfg.language,
        "keep_audio": cfg.keep_audio,
    }
