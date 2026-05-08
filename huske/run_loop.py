"""Main orchestration: `huske run` and `huske recover`."""

from __future__ import annotations

import signal
import threading
import time
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from huske import logging_setup, paths
from huske.capture.coordinator import CaptureCoordinator
from huske.capture.devices import resolve_input_device, validate_device
from huske.chunker.rotator import ChunkRotator
from huske.config import RuntimeConfig, load_config
from huske.models import AudioChunk, AudioSource, RenderState, SessionState
from huske.output_readme import ensure_output_readme
from huske.recovery.scanner import (
    RecoveryReport,
    cleanup_session_dir,
    move_to_incomplete,
    scan_orphans,
)
from huske.screenshots import ScreenshotCapturer
from huske.session import RecordingSession
from huske.transcribe.worker import TranscriptionWorker, chunk_to_job
from huske.ui.live import LiveUI


_HEARTBEAT_TIMEOUT_SECONDS = 5.0


def _print(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# huske run
# ---------------------------------------------------------------------------


def run_session(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
) -> int:
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    # Eager directory + README.
    cfg.output_root.mkdir(parents=True, exist_ok=True)
    cfg.audio_root.mkdir(parents=True, exist_ok=True)
    cfg.logs_root.mkdir(parents=True, exist_ok=True)
    ensure_output_readme(cfg.output_root)

    # Session.
    session = RecordingSession(config=cfg)
    log_path = paths.logs_path(cfg, session.session_id)
    logging_setup.configure(log_path, level=cfg.log_level, console=cfg.no_ui)
    log = logging_setup.get_logger("huske.run")
    log.info("starting", session_id=session.session_id, version_hint="v0.1.0")

    # Resolve + validate input device.
    device = resolve_input_device(cfg.input_device)
    report = validate_device(device)
    if not report.ok:
        for issue in report.issues:
            _print(f"[error] {issue}")
        for s in report.suggestions:
            _print(f"  hint: {s}")
        return 3
    assert report.device is not None
    if report.suggestions:
        for s in report.suggestions:
            log.warning("device_suggestion", message=s)

    # We always mix down to mono — Whisper is mono and downmixing avoids extra work.
    cfg = cfg.model_copy(update={"channels": 1})

    # Worker.
    worker = TranscriptionWorker()
    worker.start()

    # Render state.
    state = RenderState(
        session_id=session.session_id,
        output_root=cfg.output_root,
        recording=False,
    )

    # Recovery before starting new capture.
    rec_report = _do_recovery(cfg, worker, log)
    if rec_report.chunks_valid:
        state.push_event(
            "info",
            f"recovered {rec_report.chunks_valid} orphan chunk(s) from prior runs",
        )

    # Acquire lock.
    session.acquire_lock()
    session.state = SessionState.RECORDING

    # Wire chunker → worker.
    pending_chunks: set[int] = set()
    pending_lock = threading.Lock()

    def on_finalized(chunk: AudioChunk) -> None:
        with pending_lock:
            pending_chunks.add(chunk.chunk_seq)
        worker.submit(chunk_to_job(chunk, cfg))
        state.update(queue_depth=worker.queue_depth)
        state.push_event(
            "info",
            f"chunk {chunk.chunk_seq:03d} queued for transcription",
        )

    def on_result(seq: int) -> None:
        with pending_lock:
            pending_chunks.discard(seq)

    def on_event(severity: str, message: str) -> None:
        state.push_event(severity, message)  # type: ignore[arg-type]
        log.info("capture_event", severity=severity, message=message)

    rotator = ChunkRotator(
        cfg=cfg,
        session_id=session.session_id,
        on_finalized=on_finalized,
        on_event=on_event,
        default_audio_sources=["microphone", "system"],
    )

    capture = CaptureCoordinator(
        cfg=cfg,
        mic_device_index=report.device.index,
        sink=rotator,
        on_event=on_event,
        on_warning=lambda key, msg: state.set_warning(key, msg),
        on_warning_clear=lambda key: state.clear_warning(key),
    )

    stop_flag = threading.Event()

    def _signal_handler(signum: int, frame: object) -> None:
        if not stop_flag.is_set():
            on_event("info", "stop signal received — finalizing current chunk…")
            stop_flag.set()

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    capture.start()
    # Reflect the actual sources in the chunker's metadata default.
    actual_sources: list[AudioSource] = []
    if capture.mic_active:
        actual_sources.append("microphone")
    if capture.system_active:
        actual_sources.append("system")
    rotator.set_default_audio_sources(list(actual_sources))
    state.update(recording=True)

    screenshotter: ScreenshotCapturer | None = None
    if cfg.screenshots_enabled:
        cfg.screenshots_root.mkdir(parents=True, exist_ok=True)
        screenshotter = ScreenshotCapturer(
            cfg=cfg, session_id=session.session_id, on_event=on_event
        )
        screenshotter.start()
        on_event(
            "info",
            f"screenshots every {cfg.screenshots_interval_seconds:g}s → {cfg.screenshots_root}",
        )

    exit_code = 0

    def _session_loop(ui: LiveUI | None) -> None:
        # Phase 1: normal recording — runs until Ctrl+C / SIGTERM sets stop_flag.
        _main_loop(
            cfg, state, rotator, capture, worker, stop_flag, log,
            on_result, ui=ui,
        )

        # Phase 2: stopping. Keep the UI alive while we drain.
        state.update(recording=False, stopping=True)
        if ui is not None:
            ui.update()

        on_event("info", "stopping capture…")
        capture.stop()
        if screenshotter is not None:
            screenshotter.stop()
            on_event("info", f"screenshots saved: {screenshotter.captures}")
        rotator.finalize_current()
        if ui is not None:
            ui.update()

        with pending_lock:
            pending_count = len(pending_chunks)
        on_event("info", f"draining {pending_count} transcription(s)…")
        state.update(queue_depth=worker.queue_depth)
        if ui is not None:
            ui.update()

        deadline = time.monotonic() + 600.0  # 10 min hard cap
        last_ui_update = 0.0
        while True:
            with pending_lock:
                if not pending_chunks:
                    break
            if time.monotonic() >= deadline:
                on_event("error", "drain timed out")
                break
            result = worker.poll_result(timeout=0.1)
            if result is not None:
                seq = result["chunk_seq"]
                on_result(seq)
                if result["ok"]:
                    state.update(last_saved=Path(result["transcript_path"]))
                    on_event(
                        "info",
                        f"chunk {seq:03d} → {Path(result['transcript_path']).name}",
                    )
                else:
                    on_event(
                        "error",
                        f"chunk {seq:03d} failed: {result['error'].splitlines()[0]}",
                    )
            elif not worker.alive:
                on_event("error", "worker exited unexpectedly")
                break

            now = time.monotonic()
            if now - last_ui_update >= 0.25:
                state.update(queue_depth=worker.queue_depth)
                if ui is not None:
                    ui.update()
                last_ui_update = now

        # Final UI update so the user sees "0 pending" before we tear down.
        state.update(queue_depth=0)
        if ui is not None:
            ui.update()

    try:
        if cfg.no_ui:
            _print(f"[huske] recording — Ctrl+C to stop. transcripts → {cfg.output_root}")
            _session_loop(ui=None)
        else:
            with LiveUI(state) as live:
                _session_loop(ui=live)
    except Exception as exc:  # noqa: BLE001
        log.error("run_failed", error=str(exc))
        exit_code = 1
    finally:
        if screenshotter is not None and screenshotter.alive:
            screenshotter.stop(timeout=1.0)
        worker.stop(drain_timeout=5.0)
        session.release_lock()
        cleanup_session_dir(session.audio_root)
        session.state = SessionState.STOPPED
        log.info("stopped")

    return exit_code


def _main_loop(
    cfg: RuntimeConfig,
    state: RenderState,
    rotator: ChunkRotator,
    capture: CaptureCoordinator,
    worker: TranscriptionWorker,
    stop_flag: threading.Event,
    log: Any,
    on_result: "Callable[[int], None]",
    ui: LiveUI | None,
) -> None:
    """Run the asyncio-free main loop. Updates UI, polls worker results, watches heartbeat."""
    while not stop_flag.is_set():
        # Heartbeat / sleep-wake monitor.
        last = capture.last_callback_at
        if last is not None:
            stale = (datetime.now().astimezone() - last).total_seconds()
            if stale > _HEARTBEAT_TIMEOUT_SECONDS:
                state.set_warning(
                    "heartbeat",
                    f"no audio for {stale:.0f}s — device may be asleep/disconnected",
                )
            else:
                state.clear_warning("heartbeat")

        # Worker result drain (non-blocking).
        result = worker.poll_result(timeout=0.0)
        if result is not None:
            seq = result["chunk_seq"]
            on_result(seq)
            if result["ok"]:
                tp = Path(result["transcript_path"])
                state.update(last_saved=tp, queue_depth=worker.queue_depth)
                state.push_event("info", f"chunk {seq:03d} → {tp.name}")
            else:
                state.push_event(
                    "error",
                    f"chunk {seq:03d} failed: {result['error'].splitlines()[0]}",
                )

        # UI render-state refresh.
        peaks = capture.peak_levels_db()
        chunk = rotator.current_chunk
        state.update(
            peak_levels=peaks,
            current_chunk_seq=rotator.current_chunk_seq,
            chunk_started_at=rotator.chunk_started_at,
            next_rotation_at=rotator.next_rotation_at,
            queue_depth=worker.queue_depth,
        )

        if ui is not None:
            ui.update()

        time.sleep(0.125)  # 8 Hz


# ---------------------------------------------------------------------------
# huske recover
# ---------------------------------------------------------------------------


def run_recover(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
) -> int:
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    cfg.output_root.mkdir(parents=True, exist_ok=True)
    cfg.audio_root.mkdir(parents=True, exist_ok=True)
    cfg.logs_root.mkdir(parents=True, exist_ok=True)
    ensure_output_readme(cfg.output_root)

    log_path = cfg.logs_root / f"recover_{datetime.now().strftime('%Y%m%dT%H%M%S')}.log"
    logging_setup.configure(log_path, level=cfg.log_level, console=True)
    log = logging_setup.get_logger("huske.recover")

    worker = TranscriptionWorker()
    worker.start()
    try:
        report = _do_recovery(cfg, worker, log)
    finally:
        # Drain results before exit.
        deadline = time.monotonic() + 600.0
        seen = 0
        while seen < report.chunks_valid and time.monotonic() < deadline:
            result = worker.poll_result(timeout=1.0)
            if result is None:
                if not worker.alive:
                    break
                continue
            seen += 1
            if result["ok"]:
                _print(f"[ok]   chunk {result['chunk_seq']:03d} → {result['transcript_path']}")
            else:
                _print(f"[fail] chunk {result['chunk_seq']:03d}: {result['error'].splitlines()[0]}")
        worker.stop(drain_timeout=5.0)

    _print(
        f"\n{report.chunks_valid} chunks transcribed, "
        f"{report.chunks_incomplete} moved to incomplete/ across "
        f"{report.sessions_scanned} session(s)."
    )
    return 0 if report.chunks_incomplete == 0 or report.chunks_valid > 0 else 1


def _do_recovery(
    cfg: RuntimeConfig, worker: TranscriptionWorker, log: Any
) -> RecoveryReport:
    report = RecoveryReport()
    orphans = scan_orphans(cfg)
    report.sessions_scanned = len(orphans)
    for sess in orphans:
        log.info("orphan_session", session_id=sess.session_id, chunks=len(sess.chunks))
        for chunk in sess.chunks:
            if chunk.valid:
                # Build a synthetic AudioChunk for the worker job.
                end_time = chunk.start_time + timedelta(seconds=chunk.duration_seconds)
                ac = AudioChunk(
                    chunk_seq=chunk.chunk_seq,
                    session_id=sess.session_id,
                    start_time=chunk.start_time,
                    end_time=end_time,
                    expected_duration_seconds=cfg.chunk_seconds,
                    actual_duration_seconds=chunk.duration_seconds,
                    audio_path=chunk.audio_path,
                )
                # Mark as incomplete (recovered).
                ac.audio_sources = ["microphone"]  # unknown; safe default
                worker.submit(chunk_to_job(ac, cfg) | {"incomplete": True})
                report.chunks_valid += 1
            else:
                target = move_to_incomplete(cfg, sess.session_id, chunk.audio_path)
                report.moved_to_incomplete.append(target)
                report.chunks_incomplete += 1
        # Lock cleanup + dir cleanup attempted lazily; actual removal happens after
        # successful transcription (worker deletes WAV unless --keep-audio, then dir
        # becomes empty and `cleanup_session_dir` removes it on next opportunity).
        try:
            (sess.audio_dir / ".lock").unlink(missing_ok=True)
        except OSError:
            pass
        cleanup_session_dir(sess.audio_dir)
    return report
