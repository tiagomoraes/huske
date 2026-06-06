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
import signal
import traceback
from dataclasses import dataclass
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


@dataclass
class TranscribeResult:
    chunk_seq: int
    ok: bool
    transcript_path: str | None
    error: str | None


_SENTINEL = "__STOP__"


_READY_MSG = "__READY__"


# Whisper can hallucinate short repeated phrases on quiet microphone noise. Keep
# this gate conservative: fail open on read errors, and only drop a segment when
# the corresponding audio window is close to the source noise floor.
_ENERGY_BLOCK_SECONDS = 0.10
_SEGMENT_CONTEXT_SECONDS = 0.20
_MIN_ENERGY_WINDOW_SECONDS = 0.35
_ABSOLUTE_RMS_FLOOR = 10 ** (-55.0 / 20.0)
_ABSOLUTE_PEAK_FLOOR = 10 ** (-42.0 / 20.0)
_MAX_RMS_FLOOR = 10 ** (-42.0 / 20.0)
_MAX_PEAK_FLOOR = 10 ** (-30.0 / 20.0)
_NOISE_RMS_PERCENTILE = 20.0
_RMS_NOISE_MULTIPLIER = 3.0
_PEAK_NOISE_MULTIPLIER = 8.0


@dataclass(frozen=True)
class _AudioEnergyGate:
    path: str
    sample_rate: int
    frames: int
    rms_floor: float
    peak_floor: float

    @classmethod
    def from_path(cls, path: str) -> _AudioEnergyGate:
        import numpy as np
        import soundfile as sf

        block_rms: list[float] = []
        with sf.SoundFile(path) as audio:
            sample_rate = int(audio.samplerate)
            frames = len(audio)
            block_frames = max(1, round(sample_rate * _ENERGY_BLOCK_SECONDS))

            while True:
                data = audio.read(
                    frames=block_frames,
                    dtype="float32",
                    always_2d=False,
                )
                if data.size == 0:
                    break
                mono = _mono_float32(data)
                block_rms.append(_rms(mono))

        noise_rms = (
            float(np.percentile(block_rms, _NOISE_RMS_PERCENTILE))
            if block_rms
            else 0.0
        )
        return cls(
            path=path,
            sample_rate=sample_rate,
            frames=frames,
            rms_floor=max(
                _ABSOLUTE_RMS_FLOOR,
                min(_MAX_RMS_FLOOR, noise_rms * _RMS_NOISE_MULTIPLIER),
            ),
            peak_floor=max(
                _ABSOLUTE_PEAK_FLOOR,
                min(_MAX_PEAK_FLOOR, noise_rms * _PEAK_NOISE_MULTIPLIER),
            ),
        )

    def has_signal(self, start_seconds: float, end_seconds: float) -> bool:
        import soundfile as sf

        if self.frames <= 0:
            return False

        start = max(0.0, start_seconds - _SEGMENT_CONTEXT_SECONDS)
        end = max(
            end_seconds + _SEGMENT_CONTEXT_SECONDS,
            start + _MIN_ENERGY_WINDOW_SECONDS,
        )
        start_frame = min(self.frames, max(0, int(start * self.sample_rate)))
        end_frame = min(self.frames, max(start_frame + 1, int(end * self.sample_rate)))
        if end_frame <= start_frame:
            return False

        try:
            with sf.SoundFile(self.path) as audio:
                audio.seek(start_frame)
                data = audio.read(
                    frames=end_frame - start_frame,
                    dtype="float32",
                    always_2d=False,
                )

            if data.size == 0:
                return False
            mono = _mono_float32(data)
            return _rms(mono) >= self.rms_floor or float(abs(mono).max()) >= self.peak_floor
        except Exception:
            return True


def _mono_float32(data: Any) -> Any:
    if getattr(data, "ndim", 1) == 1:
        return data
    if data.shape[1] == 1:
        return data[:, 0]
    return data.mean(axis=1)


def _rms(data: Any) -> float:
    import numpy as np

    if data.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(data, dtype=np.float64))))


def _configure_worker_signal_handlers() -> None:
    """Let the parent process own terminal Ctrl+C shutdown."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def _unload_whisper_model(mx: Any) -> None:
    """Drop the cached whisper model and release the Metal buffer pool so the
    OS can reclaim the resident weights during long idle gaps. mlx-whisper's
    ``ModelHolder`` reloads the model lazily on the next ``transcribe`` call.
    Best-effort: never raises into the worker loop.
    """
    try:
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.model = None
        ModelHolder.model_path = None
    except Exception:
        pass
    try:
        mx.clear_cache()
    except Exception:
        pass


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


def _resolve_model_dir(hf_repo: str) -> str:
    """Resolve ``hf_repo`` to a concrete on-disk snapshot directory.

    mlx-whisper's ``load_model`` only calls ``snapshot_download`` when the path
    does not exist on disk, so passing a resolved local directory makes every
    reload after an idle unload load straight from the cache and keeps the
    ``ModelHolder`` cache key stable across reloads.

    Resolution itself stays local-only (``local_files_only=True``): it never
    reaches the network. If the model isn't cached (or resolution otherwise
    fails) it returns the repo id unchanged, so the *first* transcribe loads
    it via mlx-whisper's normal download path — the one place network is
    expected — and subsequent reloads use the now-cached dir.
    """
    from pathlib import Path as _Path

    if _Path(hf_repo).exists():
        return hf_repo
    try:
        from huggingface_hub import snapshot_download

        return snapshot_download(repo_id=hf_repo, local_files_only=True)
    except Exception:
        return hf_repo


def _worker_main(in_q: Any, out_q: Any) -> None:
    """Subprocess entry point. Loops on jobs until sentinel arrives."""
    _configure_worker_signal_handlers()

    from huske.proctitle import set_process_title

    set_process_title("huske-whisper")

    # Defer heavy imports until inside the subprocess.
    from datetime import datetime as _dt
    from pathlib import Path as _Path

    import mlx.core as mx
    import mlx_whisper

    # Force the Metal context to initialize *before* the parent process can
    # start the Core Audio tap. If the worker's first Metal allocation happens
    # after the parent has loaded the Core Audio Tap framework, the spawned
    # subprocess gets silently killed (SIGKILL with no Python traceback) the
    # moment mlx-whisper tries to load model weights. The mechanism appears
    # to be Mach-port / framework state inherited across spawn. Eagerly
    # touching Metal here keeps the worker alive for the rest of the session.
    # On a cold M-series chip, this can take 20-40 s as Metal compiles its
    # kernels for the first time; the parent's ``wait_ready`` timeout has to
    # be sized accordingly.
    mx.eval(mx.zeros(1))
    out_q.put(_READY_MSG)

    from huske.config import mlx_whisper_repo
    from huske.models import AudioChunk
    from huske.paths import transcript_filename
    from huske.transcribe.writer import (
        build_transcript_from_segments,
        write_transcript,
    )

    # Idle-unload state: when enabled (config `whisper_idle_unload`), the worker
    # drops the model after `idle_unload_seconds` of no jobs so the OS reclaims
    # the resident weights between chunks; the next job reloads it. Default off.
    model_resident = False
    idle_unload = False
    idle_unload_seconds = 120.0
    resolved_repo: dict[str, str] = {}

    while True:
        msg = _next_message(in_q, model_resident, idle_unload, idle_unload_seconds)
        if msg is _IDLE_TIMEOUT:
            # Genuinely idle past the window — reclaim the model until the next
            # job. Safe even if the model isn't actually loaded (no-op).
            _unload_whisper_model(mx)
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
            model_size = job_data["config_model"]
            hf_repo = mlx_whisper_repo(model_size)
            if idle_unload:
                # Pin a concrete local snapshot dir so post-unload reloads load
                # from disk with no network and a stable ModelHolder cache key.
                if model_size not in resolved_repo:
                    resolved_repo[model_size] = _resolve_model_dir(hf_repo)
                hf_repo = resolved_repo[model_size]
            # Map legacy CTranslate2 compute_type to mlx fp16 on/off. Anything
            # other than float32 stays on the fp16 default — that's the only
            # knob mlx-whisper exposes here.
            fp16 = job_data.get("config_compute_type") != "float32"

            audio_paths: dict[str, str] = dict(job_data["audio_paths"])
            language = job_data["language"]
            transcribe_kwargs: dict[str, Any] = {
                "path_or_hf_repo": hf_repo,
                "fp16": fp16,
                "verbose": None,
            }
            if language:
                transcribe_kwargs["language"] = language

            # Process sources in `audio_sources` order so the merged transcript
            # has stable ordering across runs (concurrent segments break ties
            # by source order, not dict iteration order).
            ordered_sources: list[str] = []
            for s in job_data.get("audio_sources") or []:
                if s in audio_paths and s not in ordered_sources:
                    ordered_sources.append(s)
            for s in audio_paths:
                if s not in ordered_sources:
                    ordered_sources.append(s)

            merged_segments: list[dict[str, Any]] = []
            detected_language: str | None = None
            # The transcribe call below loads the model into mlx-whisper's
            # ModelHolder. Arm the idle-unload flag *before* it runs so that if
            # this job throws after the weights become resident, the next loop
            # iteration still reaches the unload path (unloading a not-yet-loaded
            # model is a harmless no-op).
            model_resident = True
            for source in ordered_sources:
                src_path = audio_paths[source]
                try:
                    energy_gate = _AudioEnergyGate.from_path(src_path)
                except Exception:
                    energy_gate = None

                # mlx-whisper caches the loaded model across calls via
                # ModelHolder, so subsequent calls in this loop reuse it.
                src_result = mlx_whisper.transcribe(
                    src_path,
                    condition_on_previous_text=False,
                    **transcribe_kwargs,
                )
                source_language = src_result.get("language")
                for seg in src_result.get("segments") or []:
                    text = (seg.get("text") or "").strip()
                    if not text:
                        continue
                    seg_start = float(seg.get("start", 0.0))
                    seg_end = float(seg.get("end", seg_start))
                    if energy_gate is not None and not energy_gate.has_signal(
                        seg_start, seg_end
                    ):
                        continue
                    if detected_language is None:
                        detected_language = source_language
                    merged_segments.append(
                        {
                            "start": seg_start,
                            "end": seg_end,
                            "text": text,
                            "source": source,
                        }
                    )

            # Stable sort: ties (same start) preserve insertion order, which
            # follows ordered_sources.
            merged_segments.sort(key=lambda s: s["start"])

            start_time = _dt.fromisoformat(job_data["start_time"])
            end_time = _dt.fromisoformat(job_data["end_time"])

            from huske.transcribe.writer import body_from_source_segments

            body = body_from_source_segments(start_time, merged_segments)

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
                language=detected_language or language or "auto",
                incomplete=job_data["incomplete"],
                text=body,
                segments=merged_segments or None,
            )

            # Build target path.
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

            # Delete per-source WAVs if not keeping audio.
            if not job_data.get("keep_audio", False):
                for p in audio_paths.values():
                    try:
                        _Path(p).unlink(missing_ok=True)
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
            # This drops only reusable buffers, not the resident model weights,
            # and is a no-op when nothing is cached — cheap, always-on hygiene
            # that helps even when whisper_idle_unload is off (model stays warm,
            # but the per-chunk working set is reclaimed).
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
        primary = (
            chunk.audio_sources[0] if chunk.audio_sources else "microphone"
        )
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
        "config_model": cfg.model,
        "config_compute_type": cfg.compute_type,
        "config_device": cfg.device,
        "language": cfg.language,
        "keep_audio": cfg.keep_audio,
        "whisper_idle_unload": cfg.whisper_idle_unload,
        "whisper_idle_unload_seconds": cfg.whisper_idle_unload_seconds,
    }
