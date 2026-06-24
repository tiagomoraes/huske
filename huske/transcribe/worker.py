"""Transcription worker subprocess.

Why a subprocess? The ASR backends (Parakeet / Whisper) do Metal-bound
inference that releases the GIL, but the model loads (~hundreds of MB to GPU)
and audio decoding happen on the Python side and would still hitch the audio
drainer if run in-process. A spawn subprocess also keeps the worker's MLX state
isolated from PortAudio in the parent.

The worker is engine-agnostic: it builds one ``TranscriptionEngine`` (see
``huske.transcribe.engines``) per session from the job's ``asr_engine`` field,
transcribes each per-source WAV, tags the segments with their source,
de-duplicates cross-channel echo, and renders the Markdown transcript.
"""

from __future__ import annotations

import multiprocessing as mp
import queue
import signal
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Use spawn on macOS to keep PortAudio out of the child.
_ctx = mp.get_context("spawn")


@dataclass
class TranscribeJob:
    chunk_seq: int
    session_id: str
    audio_paths: dict[str, str]  # source -> WAV path
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
    keep_audio_format: str = "wav"


@dataclass
class TranscribeResult:
    chunk_seq: int
    ok: bool
    transcript_path: str | None
    error: str | None


# format -> (libsndfile container, subtype, file extension)
_KEEP_AUDIO_SPECS: dict[str, tuple[str, str | None, str]] = {
    "opus": ("OGG", "OPUS", ".opus"),
    "flac": ("FLAC", None, ".flac"),
}


def _compress_kept_audio(wav_path: Path, fmt: str) -> None:
    """Transcode a finished chunk WAV to a compressed sibling, then drop the WAV.

    The ASR engine has already read the WAV, so the codec is irrelevant to the
    transcript — this only shrinks what ``--keep-audio`` leaves on disk. Encoded
    with libsndfile via ``soundfile`` (no extra dependency). Best-effort: on any
    failure the original WAV is kept and any partial output removed.
    """
    spec = _KEEP_AUDIO_SPECS.get(fmt)
    if spec is None:
        return
    container, subtype, ext = spec
    out = wav_path.with_suffix(ext)
    try:
        import soundfile as sf

        data, sr = sf.read(str(wav_path), dtype="float32")
        if subtype is not None:
            sf.write(str(out), data, sr, format=container, subtype=subtype)
        else:
            sf.write(str(out), data, sr, format=container)
        wav_path.unlink(missing_ok=True)
    except Exception:
        out.unlink(missing_ok=True)  # drop any half-written file; keep the WAV


_SENTINEL = "__STOP__"
_READY_MSG = "__READY__"


def _configure_worker_signal_handlers() -> None:
    """Let the parent process own terminal Ctrl+C shutdown."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)


# Returned by ``_next_message`` when the idle window elapsed with no new job.
_IDLE_TIMEOUT = object()


def _next_message(
    in_q: Any,
    model_resident: bool,
    idle_unload: bool,
    idle_unload_seconds: float,
) -> Any:
    """Block for the next job message off ``in_q``.

    When the model is resident and idle-unload is enabled, wait at most
    ``idle_unload_seconds`` and return ``_IDLE_TIMEOUT`` if nothing arrives, so
    the caller can drop the model and keep waiting. Otherwise block
    indefinitely — there is no point timing out when nothing is resident to
    free, and a queued backlog keeps the model warm by arriving in time.
    """
    if model_resident and idle_unload:
        try:
            return in_q.get(timeout=idle_unload_seconds)
        except queue.Empty:
            return _IDLE_TIMEOUT
    return in_q.get()


def _ordered_sources(audio_paths: dict[str, str], audio_sources: list[str]) -> list[str]:
    """Sources to transcribe, in ``audio_sources`` order then any extras.

    Stable ordering keeps the merged transcript deterministic across runs and
    makes concurrent same-start segments break ties by source, not dict order.
    """
    ordered: list[str] = []
    for s in audio_sources or []:
        if s in audio_paths and s not in ordered:
            ordered.append(s)
    for s in audio_paths:
        if s not in ordered:
            ordered.append(s)
    return ordered


def _worker_main(in_q: Any, out_q: Any) -> None:
    """Subprocess entry point. Loops on jobs until sentinel arrives."""
    _configure_worker_signal_handlers()

    from huske.proctitle import set_process_title

    set_process_title("huske-asr")

    # Defer heavy imports until inside the subprocess.
    from datetime import datetime as _dt
    from pathlib import Path as _Path

    import mlx.core as mx

    # Force the Metal context to initialize *before* the parent process can
    # start the Core Audio tap. If the worker's first Metal allocation happens
    # after the parent has loaded the Core Audio Tap framework, the spawned
    # subprocess gets silently killed (SIGKILL with no Python traceback) the
    # moment the backend tries to load model weights. The mechanism appears to
    # be Mach-port / framework state inherited across spawn. Eagerly touching
    # Metal here keeps the worker alive for the rest of the session. On a cold
    # M-series chip, this can take 20-40 s as Metal compiles its kernels for the
    # first time; the parent's ``wait_ready`` timeout has to be sized to match.
    mx.eval(mx.zeros(1))
    out_q.put(_READY_MSG)

    from huske.models import AudioChunk
    from huske.paths import transcript_filename
    from huske.transcribe.dedup import mark_cross_channel_echoes
    from huske.transcribe.engines import Segment, build_engine
    from huske.transcribe.engines.base import load_mono_16k
    from huske.transcribe.writer import (
        body_from_source_segments,
        build_transcript_from_segments,
        write_transcript,
    )

    # The engine persists for the worker's lifetime; ``unload`` drops only its
    # resident model so the next job reloads it (idle-unload). Rebuilt only if
    # the job's engine selection changes (it never does mid-session).
    engine: Any = None
    engine_key: tuple[str, str, str | None] | None = None
    model_resident = False
    idle_unload = False
    idle_unload_seconds = 120.0

    while True:
        msg = _next_message(in_q, model_resident, idle_unload, idle_unload_seconds)
        if msg is _IDLE_TIMEOUT:
            # Genuinely idle past the window — reclaim the model until the next
            # job. Safe even if nothing is loaded (no-op).
            if engine is not None:
                engine.unload()
            model_resident = False
            continue
        if msg == _SENTINEL:
            return
        if not isinstance(msg, dict):
            continue
        job_data = msg
        idle_unload = bool(job_data.get("whisper_idle_unload", False))
        idle_unload_seconds = float(job_data.get("whisper_idle_unload_seconds", 120.0))
        try:
            asr_engine = job_data.get("asr_engine", "parakeet")
            model_size = job_data["config_model"]
            parakeet_model = job_data.get(
                "parakeet_model", "mlx-community/parakeet-tdt-0.6b-v3"
            )
            language = job_data["language"]

            key = (asr_engine, model_size, parakeet_model)
            if engine is None or key != engine_key:
                engine = build_engine(
                    asr_engine,
                    model=model_size,
                    parakeet_model=parakeet_model,
                    language=language,
                    compute_type=job_data.get("config_compute_type", "int8"),
                )
                engine_key = key

            audio_paths: dict[str, str] = dict(job_data["audio_paths"])
            sources = _ordered_sources(audio_paths, job_data.get("audio_sources") or [])

            # Load each source as 16 kHz mono (the worker owns audio I/O so it
            # can cancel echo before transcription).
            arrays = {src: load_mono_16k(audio_paths[src]) for src in sources}

            # Acoustic echo cancellation: remove the system audio that bled into
            # the mic over speakers, using the clean system channel as the
            # far-end reference, *before* transcription. Self-gating — with
            # headphones there is no coherent echo path and the mic passes
            # through. The transcript-level dedup below is the backstop.
            if (
                job_data.get("echo_cancel", True)
                and "microphone" in arrays
                and "system" in arrays
                and arrays["microphone"].size
                and arrays["system"].size
            ):
                from huske.transcribe.aec import cancel_echo

                arrays["microphone"] = cancel_echo(
                    arrays["microphone"], arrays["system"]
                )

            # Arm idle-unload *before* the first transcribe loads weights, so a
            # mid-job throw still reaches the unload path next iteration.
            model_resident = True
            merged: list[Segment] = []
            for source in sources:
                for seg in engine.transcribe(arrays[source]):
                    seg.source = source
                    merged.append(seg)

            # Stable sort: ties (same start) preserve source order.
            merged.sort(key=lambda s: (s.start, s.source))

            echo_mode = job_data.get("echo_dedup", "drop")
            if echo_mode != "off":
                mark_cross_channel_echoes(merged)

            seg_dicts: list[dict[str, Any]] = []
            for s in merged:
                if s.echo and echo_mode == "drop":
                    continue
                seg_dicts.append(
                    {
                        "start": s.start,
                        "end": s.end,
                        "text": s.text,
                        "source": s.source,
                        "echo": s.echo,
                        "confidence": s.confidence,
                    }
                )

            start_time = _dt.fromisoformat(job_data["start_time"])
            end_time = _dt.fromisoformat(job_data["end_time"])

            body = body_from_source_segments(start_time, seg_dicts)

            transcript = build_transcript_from_segments(
                session_id=job_data["session_id"],
                chunk_seq=job_data["chunk_seq"],
                start_time=start_time,
                end_time=end_time,
                expected_duration_seconds=job_data["expected_duration_seconds"],
                actual_duration_seconds=job_data["actual_duration_seconds"],
                gap_seconds=job_data["gap_seconds"],
                audio_sources=job_data["audio_sources"],
                model=engine.model_label,
                language=language or "auto",
                incomplete=job_data["incomplete"],
                text=body,
                segments=seg_dicts or None,
            )

            output_root = _Path(job_data["output_root"])
            day = output_root / start_time.date().isoformat()
            day.mkdir(parents=True, exist_ok=True)
            primary_path = next(iter(audio_paths.values()))
            chunk_proxy = AudioChunk(
                chunk_seq=transcript.chunk_seq,
                session_id=transcript.session_id,
                start_time=transcript.start_time,
                expected_duration_seconds=transcript.duration_seconds,
                audio_path=_Path(primary_path),
            )
            target = day / transcript_filename(chunk_proxy).name
            written = write_transcript(transcript, target)

            # Audio cleanup. Without --keep-audio, drop the per-source WAVs.
            # With it, transcode each WAV to the configured (compressed) format
            # and remove the WAV so retained audio stays small.
            if not job_data.get("keep_audio", False):
                for p in audio_paths.values():
                    try:
                        _Path(p).unlink(missing_ok=True)
                    except OSError:
                        pass
            else:
                keep_format = job_data.get("keep_audio_format", "wav")
                if keep_format != "wav":
                    for p in audio_paths.values():
                        _compress_kept_audio(_Path(p), keep_format)

            out_q.put(
                {
                    "chunk_seq": job_data["chunk_seq"],
                    "ok": True,
                    "transcript_path": str(written),
                    "error": None,
                }
            )
        except Exception as exc:
            tb = traceback.format_exc()
            out_q.put(
                {
                    "chunk_seq": job_data.get("chunk_seq", -1),
                    "ok": False,
                    "transcript_path": None,
                    "error": f"{exc}\n{tb}",
                }
            )
        finally:
            # Release the transient Metal buffer pool after every job so the
            # decode/encode working set doesn't stay pinned through the idle gap.
            try:
                mx.clear_cache()
            except Exception:
                pass


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
            target=_worker_main,
            args=(self._in_q, self._out_q),
            name="huske-worker",
        )
        self._proc.start()

    def wait_ready(self, timeout: float = 90.0) -> bool:
        """Block until the worker has finished its eager Metal init.

        Returns True on readiness, False on timeout or worker death. Capture
        must not start until this returns True — see ``_worker_main`` for
        the rationale.
        """
        import time

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                msg = self._out_q.get(timeout=0.5)
                if msg == _READY_MSG:
                    return True
            except queue.Empty:
                if self._proc is None or not self._proc.is_alive():
                    return False
        return False

    def submit(self, job: dict[str, Any]) -> None:
        self._in_q.put(job)

    def poll_result(self, timeout: float = 0.0) -> dict[str, Any] | None:
        try:
            msg = self._out_q.get(timeout=timeout)
        except queue.Empty:
            return None
        if isinstance(msg, dict):
            return msg
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
        # NOTE: mp.Queue.qsize() raises NotImplementedError on macOS, so this
        # returns 0 there. The orchestrator tracks the true in-flight count via
        # `pending_chunks` (run_loop) and drives the UI from that; this property
        # is kept for Linux/tests and rough display only.
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
    if chunk.audio_paths:
        audio_paths = {s: str(p) for s, p in chunk.audio_paths.items()}
    else:
        # Recovery path: only the legacy single audio_path is known. Tag it
        # under the first source label so the worker can still process it.
        primary = chunk.audio_sources[0] if chunk.audio_sources else "microphone"
        audio_paths = {primary: str(chunk.audio_path)}
    return {
        "chunk_seq": chunk.chunk_seq,
        "session_id": chunk.session_id,
        "audio_paths": audio_paths,
        "start_time": chunk.start_time.isoformat(),
        "end_time": (chunk.end_time or chunk.start_time).isoformat(),
        "expected_duration_seconds": float(chunk.expected_duration_seconds),
        "actual_duration_seconds": float(chunk.actual_duration_seconds or 0.0),
        "gap_seconds": float(chunk.gap_seconds),
        "audio_sources": list(chunk.audio_sources),
        "incomplete": bool(chunk.is_partial),
        "output_root": str(cfg.output_root),
        "asr_engine": cfg.asr_engine,
        "config_model": cfg.model,
        "parakeet_model": cfg.parakeet_model,
        "config_compute_type": cfg.compute_type,
        "config_device": cfg.device,
        "language": cfg.language,
        "echo_cancel": cfg.echo_cancel,
        "echo_dedup": cfg.echo_dedup,
        "keep_audio": cfg.keep_audio,
        "keep_audio_format": cfg.keep_audio_format,
        "whisper_idle_unload": cfg.whisper_idle_unload,
        "whisper_idle_unload_seconds": cfg.whisper_idle_unload_seconds,
    }
