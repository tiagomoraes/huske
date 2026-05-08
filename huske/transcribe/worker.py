"""Transcription worker subprocess.

Why a subprocess? mlx-whisper does Metal-bound inference that releases the
GIL, but the model loads (~hundreds of MB to GPU) and audio decoding happen
on the Python side and would still hitch the audio drainer if run in-process.
A spawn subprocess also keeps the worker's MLX state isolated from PortAudio
in the parent.
"""

from __future__ import annotations

import multiprocessing as mp
import queue
import traceback
from dataclasses import dataclass
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

    import mlx_whisper

    from huske.config import mlx_whisper_repo
    from huske.models import AudioChunk
    from huske.paths import transcript_filename
    from huske.transcribe.writer import (
        build_transcript_from_segments,
        write_transcript,
    )

    while True:
        msg = in_q.get()
        if msg == _SENTINEL:
            return
        if not isinstance(msg, dict):
            continue
        job_data = msg
        try:
            model_size = job_data["config_model"]
            hf_repo = mlx_whisper_repo(model_size)
            # Map legacy CTranslate2 compute_type to mlx fp16 on/off. Anything
            # other than float32 stays on the fp16 default — that's the only
            # knob mlx-whisper exposes here.
            fp16 = job_data.get("config_compute_type") != "float32"

            audio_path = job_data["audio_path"]
            language = job_data["language"]
            transcribe_kwargs: dict[str, Any] = {
                "path_or_hf_repo": hf_repo,
                "fp16": fp16,
                "verbose": None,
            }
            if language:
                transcribe_kwargs["language"] = language

            # mlx-whisper caches the loaded model across calls via ModelHolder,
            # so the first job pays the load cost and subsequent jobs reuse it.
            result = mlx_whisper.transcribe(audio_path, **transcribe_kwargs)

            seg_list: list[dict] = []
            text_parts: list[str] = []
            for seg in result.get("segments") or []:
                text = (seg.get("text") or "").strip()
                seg_list.append(
                    {
                        "start": float(seg.get("start", 0.0)),
                        "end": float(seg.get("end", 0.0)),
                        "text": text,
                    }
                )
                if text:
                    text_parts.append(text)
            body = "\n\n".join(text_parts)

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
                model=f"mlx-whisper:{model_size}",
                language=result.get("language") or language or "auto",
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
