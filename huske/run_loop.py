"""Main orchestration: `huske run` and `huske recover`."""

from __future__ import annotations

import signal
import subprocess
import sys
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
from huske.control import Command, CommandChannel
from huske.ipc import ControlServer
from huske.ipc.protocol import ControlSnapshot
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
from huske.ui.input import TerminalKeyReader
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

    # Worker. Block until the subprocess has eagerly initialized Metal —
    # if Core Audio capture starts first the worker dies silently on its
    # first Metal allocation. The cold-start cost is one-off per session
    # (~30 s on M-series) and replaces the same wait we would otherwise
    # see at the first chunk.
    worker = TranscriptionWorker()
    worker.start()
    _print("[huske] warming up transcription engine (mlx Metal)…")
    if not worker.wait_ready(timeout=90.0):
        _print(
            "[error] transcription worker did not initialize within 90s — aborting"
        )
        worker.stop(drain_timeout=2.0)
        return 4

    # Render state.
    state = RenderState(
        session_id=session.session_id,
        output_root=cfg.output_root,
        recording=False,
        screenshots_enabled=False,
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
        state.update(
            screenshots_enabled=screenshotter.alive,
            screenshots_count=screenshotter.captures,
            last_screenshot_at=screenshotter.last_capture_at,
        )
        if screenshotter.alive:
            on_event(
                "info",
                f"screenshots every {cfg.screenshots_interval_seconds:g}s → {cfg.screenshots_root}",
            )

    exit_code = 0

    def _screenshot_status() -> tuple[bool, int, datetime | None]:
        if screenshotter is None:
            return False, 0, None
        return screenshotter.alive, screenshotter.captures, screenshotter.last_capture_at

    def _sync_screenshot_state() -> None:
        enabled, count, last = _screenshot_status()
        state.update(
            screenshots_enabled=enabled,
            screenshots_count=count,
            last_screenshot_at=last,
        )

    def _toggle_screenshots() -> None:
        nonlocal screenshotter
        if screenshotter is not None and screenshotter.alive:
            screenshotter.stop()
            _sync_screenshot_state()
            on_event("info", f"screenshots disabled ({screenshotter.captures} saved)")
            return

        cfg.screenshots_root.mkdir(parents=True, exist_ok=True)
        if screenshotter is None:
            screenshotter = ScreenshotCapturer(
                cfg=cfg, session_id=session.session_id, on_event=on_event
            )
        screenshotter.start()
        _sync_screenshot_state()
        if screenshotter.alive:
            on_event(
                "info",
                f"screenshots enabled every {cfg.screenshots_interval_seconds:g}s",
            )

    def _toggle_pause() -> None:
        if state.paused:
            capture.resume()
            state.clear_warning("heartbeat")
            state.update(recording=True, paused=False)
            on_event("info", "recording resumed")
            return

        capture.pause()
        finalized = rotator.pause_current()
        state.clear_warning("heartbeat")
        state.update(recording=False, paused=True, peak_levels=(-120.0, -120.0))
        msg = "recording paused"
        if finalized:
            msg += " — current chunk queued"
        on_event("info", msg)

    def _open_path(path: Path) -> None:
        if not path.exists():
            on_event("warn", f"path not found: {path}")
            return
        try:
            if sys.platform == "darwin":
                subprocess.Popen(["open", str(path)])
            elif sys.platform.startswith("linux"):
                subprocess.Popen(["xdg-open", str(path)])
            else:
                on_event("warn", f"open not supported on {sys.platform}")
        except OSError as exc:
            on_event("error", f"failed to open {path.name}: {exc}")

    def _open_transcripts() -> None:
        _open_path(cfg.output_root)

    def _open_latest_transcript() -> None:
        if state.last_saved is None:
            on_event("info", "no transcript saved yet")
            return
        _open_path(state.last_saved)

    def _stop() -> None:
        stop_flag.set()

    commands = CommandChannel()
    dispatch: dict[Command, Callable[[], None]] = {
        Command.PAUSE_RESUME: _toggle_pause,
        Command.TOGGLE_SCREENSHOTS: _toggle_screenshots,
        Command.STOP: _stop,
        Command.OPEN_TRANSCRIPTS: _open_transcripts,
        Command.OPEN_LATEST_TRANSCRIPT: _open_latest_transcript,
    }

    def _pump_commands() -> None:
        for cmd in commands.drain():
            handler = dispatch.get(cmd)
            if handler is not None:
                handler()

    server: ControlServer | None = None
    helper_proc: subprocess.Popen[bytes] | None = None
    if sys.platform == "darwin":
        socket_dir = Path.home() / "Library" / "Application Support" / "huske"
        socket_path = socket_dir / f"control-{paths.session_id_short(session.session_id)}.sock"
        server = ControlServer(socket_path, commands, log)
        try:
            server.start()
            log.info("ipc_server_started", socket=str(socket_path))
        except OSError as exc:
            log.warning("ipc_server_failed", error=str(exc))
            server = None

        if server is not None and cfg.menu_bar_enabled:
            from huske.agent import resolve_huske_binary

            argv = [
                *resolve_huske_binary(),
                "menubar",
                "--attach",
                str(server.socket_path),
                "--style",
                cfg.menu_bar_label_style,
            ]
            helper_log = cfg.logs_root / f"menubar_{session.session_id}.log"
            helper_log.parent.mkdir(parents=True, exist_ok=True)
            try:
                helper_proc = subprocess.Popen(
                    argv,
                    stdout=subprocess.DEVNULL,
                    stderr=open(helper_log, "ab"),
                    start_new_session=True,
                )
                log.info("menubar_helper_started", pid=helper_proc.pid)
            except OSError as exc:
                log.warning("menubar_helper_failed", error=str(exc))
                helper_proc = None

    last_snap: ControlSnapshot | None = None

    def _publish_state() -> None:
        nonlocal last_snap
        if server is None:
            return
        snap = ControlSnapshot(
            session_id=session.session_id,
            recording=state.recording,
            paused=state.paused,
            stopping=state.stopping,
            current_chunk_seq=state.current_chunk_seq,
            queue_depth=state.queue_depth,
            screenshots_enabled=state.screenshots_enabled,
            last_saved_name=state.last_saved.name if state.last_saved else None,
        )
        if snap == last_snap:
            return
        last_snap = snap
        server.broadcast_state(snap)

    def _handle_key(key: str) -> None:
        if stop_flag.is_set():
            return
        normalized = key.lower()
        if normalized == "\x03":
            on_event("info", "stop requested — finalizing current chunk…")
            commands.send(Command.STOP)
            return
        if normalized == "?":
            state.update(help_visible=not state.help_visible)
            return
        if not state.help_visible:
            return
        if normalized == "\x1b":
            state.update(help_visible=False)
        elif normalized == "q":
            on_event("info", "stop requested — finalizing current chunk…")
            commands.send(Command.STOP)
        elif normalized == "p":
            commands.send(Command.PAUSE_RESUME)
            state.update(help_visible=False)
        elif normalized == "s":
            commands.send(Command.TOGGLE_SCREENSHOTS)
            state.update(help_visible=False)

    def _session_loop(
        ui: LiveUI | None,
        read_key: Callable[[], str | None] | None = None,
    ) -> None:
        # Phase 1: normal recording — runs until Ctrl+C / SIGTERM sets stop_flag.
        _main_loop(
            cfg, state, rotator, capture, worker, stop_flag, log,
            on_result, ui=ui, read_key=read_key, on_key=_handle_key,
            screenshot_status=_screenshot_status,
            pump_commands=_pump_commands,
            publish_state=_publish_state,
        )

        # Phase 2: stopping. Keep the UI alive while we drain.
        state.update(recording=False, paused=False, stopping=True, help_visible=False)
        _publish_state()
        if ui is not None:
            ui.update()

        on_event("info", "stopping capture…")
        capture.stop()
        if screenshotter is not None:
            screenshotter.stop()
            _sync_screenshot_state()
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
                _publish_state()
                if ui is not None:
                    ui.update()
                last_ui_update = now

        # Final UI update so the user sees "0 pending" before we tear down.
        state.update(queue_depth=0)
        _publish_state()
        if ui is not None:
            ui.update()

    try:
        if cfg.no_ui:
            _print(f"[huske] recording — Ctrl+C to stop. transcripts → {cfg.output_root}")
            _session_loop(ui=None)
        else:
            with LiveUI(state) as live, TerminalKeyReader() as keys:
                _session_loop(ui=live, read_key=keys.read_key)
    except Exception as exc:
        log.error("run_failed", error=str(exc))
        exit_code = 1
    finally:
        if server is not None:
            server.stop(timeout=1.0)
        if helper_proc is not None and helper_proc.poll() is None:
            try:
                helper_proc.terminate()
                helper_proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                helper_proc.kill()
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
    on_result: Callable[[int], None],
    ui: LiveUI | None,
    read_key: Callable[[], str | None] | None = None,
    on_key: Callable[[str], None] | None = None,
    screenshot_status: Callable[[], tuple[bool, int, datetime | None]] | None = None,
    pump_commands: Callable[[], None] | None = None,
    publish_state: Callable[[], None] | None = None,
) -> None:
    """Run the asyncio-free main loop. Updates UI, polls worker results, watches heartbeat."""
    while not stop_flag.is_set():
        if read_key is not None and on_key is not None:
            while True:
                key = read_key()
                if key is None:
                    break
                on_key(key)
                if stop_flag.is_set():
                    break
            if stop_flag.is_set():
                break

        if pump_commands is not None:
            pump_commands()
            if stop_flag.is_set():
                break

        # Heartbeat / sleep-wake monitor.
        last = capture.last_callback_at
        if not state.paused and last is not None:
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
        screenshot_fields: dict[str, object] = {}
        if screenshot_status is not None:
            screenshots_enabled, screenshots_count, last_screenshot_at = screenshot_status()
            screenshot_fields = {
                "screenshots_enabled": screenshots_enabled,
                "screenshots_count": screenshots_count,
                "last_screenshot_at": last_screenshot_at,
            }
        state.update(
            peak_levels=peaks,
            current_chunk_seq=rotator.current_chunk_seq,
            chunk_started_at=rotator.chunk_started_at,
            next_rotation_at=rotator.next_rotation_at,
            queue_depth=worker.queue_depth,
            **screenshot_fields,
        )

        if publish_state is not None:
            publish_state()

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
            # Move any sibling WAVs that failed validity (truncated/empty) to
            # incomplete/, regardless of whether the chunk overall is valid.
            for bad in chunk.invalid_paths:
                target = move_to_incomplete(cfg, sess.session_id, bad)
                report.moved_to_incomplete.append(target)
                report.chunks_incomplete += 1

            if chunk.valid:
                end_time = chunk.start_time + timedelta(seconds=chunk.duration_seconds)
                primary = next(iter(chunk.audio_paths.values()))
                ac = AudioChunk(
                    chunk_seq=chunk.chunk_seq,
                    session_id=sess.session_id,
                    start_time=chunk.start_time,
                    end_time=end_time,
                    expected_duration_seconds=cfg.chunk_seconds,
                    actual_duration_seconds=chunk.duration_seconds,
                    audio_path=primary,
                    audio_paths=dict(chunk.audio_paths),  # type: ignore[arg-type]
                    audio_sources=list(chunk.audio_paths.keys()),  # type: ignore[arg-type]
                )
                worker.submit(chunk_to_job(ac, cfg) | {"incomplete": True})
                report.chunks_valid += 1
        # Lock cleanup + dir cleanup attempted lazily; actual removal happens after
        # successful transcription (worker deletes WAV unless --keep-audio, then dir
        # becomes empty and `cleanup_session_dir` removes it on next opportunity).
        try:
            (sess.audio_dir / ".lock").unlink(missing_ok=True)
        except OSError:
            pass
        cleanup_session_dir(sess.audio_dir)
    return report
