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

from huske import __version__, logging_setup, paths
from huske.capture.coordinator import CaptureCoordinator
from huske.capture.devices import (
    list_input_devices,
    match_input_device,
    resolve_input_device_with_fallback,
    validate_device,
)
from huske.chunker.rotator import ChunkRotator
from huske.config import RuntimeConfig, load_config, update_user_config
from huske.control import Command, CommandChannel
from huske.ipc import ControlServer
from huske.ipc.protocol import ControlSnapshot, DeviceList, InputDeviceEntry
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

_HEARTBEAT_TIMEOUT_SECONDS = 5.0


def _print(msg: str) -> None:
    print(msg, flush=True)


def build_control_snapshot(
    state: RenderState,
    *,
    session_id: str,
    session_started_at: datetime,
    output_root: Path,
    input_device_name: str | None,
) -> ControlSnapshot:
    """Serialize the live render state into a v2 control-plane snapshot.

    Pure so the wire shape the native app depends on stays unit-testable
    without running a capture session.
    """
    peaks = state.peak_levels
    return ControlSnapshot(
        session_id=session_id,
        recording=state.recording,
        paused=state.paused,
        stopping=state.stopping,
        current_chunk_seq=state.current_chunk_seq,
        queue_depth=state.queue_depth,
        screenshots_enabled=state.screenshots_enabled,
        distill_enabled=state.distill_enabled,
        last_saved_name=state.last_saved.name if state.last_saved else None,
        peak_mic_db=round(float(peaks[0]), 1) if len(peaks) >= 1 else -120.0,
        peak_system_db=round(float(peaks[1]), 1) if len(peaks) >= 2 else -120.0,
        chunk_started_at=(
            state.chunk_started_at.isoformat() if state.chunk_started_at else None
        ),
        next_rotation_at=(
            state.next_rotation_at.isoformat() if state.next_rotation_at else None
        ),
        session_started_at=session_started_at.isoformat(),
        huske_version=__version__,
        output_root=str(output_root),
        last_saved_path=str(state.last_saved) if state.last_saved else None,
        screenshots_count=state.screenshots_count,
        input_device_name=input_device_name,
        warnings=dict(state.warnings),
        events=[
            {
                "ts": ev.timestamp.isoformat(),
                "severity": ev.severity,
                "message": ev.message,
            }
            for ev in list(state.events)
        ],
    )


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
    # Headless engine: structured console logs always on (the app or the
    # menu bar helper is the UI; the terminal shows plain progress lines).
    logging_setup.configure(log_path, level=cfg.log_level, console=True)
    log = logging_setup.get_logger("huske.run")
    log.info("starting", session_id=session.session_id, version_hint=__version__)

    # A configured `language` is only a promise on whisper, whose decoder takes a
    # language token. Parakeet infers the language per decode window and can
    # collapse code-switched speech into English; huske re-decodes windows it
    # catches, but say once, up front, that the setting is a hint here.
    if cfg.language and cfg.asr_engine == "parakeet":
        _print(
            f"[warn] language={cfg.language!r} cannot be enforced by the parakeet "
            'engine — set asr_engine = "whisper" to pin it'
        )
        log.warning("language_not_enforceable", language=cfg.language, engine=cfg.asr_engine)

    # Resolve + validate input device.
    device_resolution = resolve_input_device_with_fallback(cfg.input_device)
    if device_resolution.warning:
        _print(f"[warn] {device_resolution.warning}")
        log.warning("device_resolution", message=device_resolution.warning)
    report = validate_device(device_resolution.device)
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

    # The active microphone, mirrored for control-plane snapshots. A plain
    # mutable holder because closures below rebind it on live device swaps.
    active_mic = {"name": report.device.name}

    # Optional: background embedding worker for local semantic search. Started
    # non-blocking — capture never waits on the embedding model to load, and an
    # init failure degrades to "recording continues, no indexing". See
    # docs/adr/0003-embed-worker-isolation.md.
    embed_worker = None
    if cfg.indexing_enabled:
        from huske.search.worker import EmbedWorker

        try:
            cfg.index_root.mkdir(parents=True, exist_ok=True)
            embed_worker = EmbedWorker(
                str(paths.index_db_path(cfg)),
                cfg.embedding_model,
                batch_size=cfg.embed_batch_size,
                # The same embedder embeds each transcript's distilled statements
                # into a second store. Provision it whenever indexing is on — not
                # only when distillation starts enabled — so toggling distillation
                # on mid-session (via the `?` panel / menu bar) still routes its
                # statements into the searchable statement store.
                statements_db_path=str(paths.statements_db_path(cfg)),
            )
            embed_worker.start()
            _print("[huske] indexing enabled — transcripts will be embedded in background")
        except Exception as exc:
            log.warning("embed_worker_start_failed", error=str(exc))
            embed_worker = None

    # Optional: off-device replication to a huske server. Dependency-free,
    # started non-blocking, and inert unless `sync_endpoint` is set — recording
    # never waits on the network. See docs/adr/0004-off-device-huske-server.md.
    sync_worker = None
    sync_outbox = None
    if cfg.sync_endpoint:
        from huske.mcp.token import load_token, sync_token_path
        from huske.paths import outbox_db_path
        from huske.sync.client import IngestClient
        from huske.sync.outbox import Outbox
        from huske.sync.worker import SyncWorker

        sync_token = load_token(sync_token_path())
        if not sync_token:
            _print(
                f"[warn] sync_endpoint set but no token at {sync_token_path()} — replication off"
            )
            log.warning("sync_token_missing", path=str(sync_token_path()))
        else:
            try:
                cfg.sync_root.mkdir(parents=True, exist_ok=True)
                sync_outbox = Outbox(outbox_db_path(cfg))
                sync_worker = SyncWorker(
                    cfg.output_root,
                    sync_outbox,
                    IngestClient(cfg.sync_endpoint, sync_token, verify_tls=cfg.sync_verify_tls),
                    reconcile_on_start=True,
                )
                sync_worker.start()
                _print(f"[huske] replication enabled → {cfg.sync_endpoint}")
            except Exception as exc:
                log.warning("sync_worker_start_failed", error=str(exc))
                sync_worker = None
                sync_outbox = None

    # Optional: background LLM distillation into searchable Statements. A daemon
    # *thread* — the LLM runs in its own process (Ollama), so from here it is
    # loopback HTTP, GIL-releasing, like sync. Off unless `distill_enabled` (but
    # it can be toggled on live from the `?` panel / menu bar — see
    # `_toggle_distill`). Each finished sidecar is handed to the embed worker so
    # its statements get embedded too. It does NOT reconcile history here (that's
    # `huske distill`): it only distills this session's transcripts, so enabling
    # it never kicks off a surprise whole-corpus backfill. See
    # docs/adr/0005-llm-distillation.md.
    def _build_distill_worker() -> Any:
        from huske.distill.distiller import build_distiller
        from huske.distill.worker import DistillWorker

        distiller = build_distiller(
            cfg.distill_model,
            backend=cfg.distill_backend,
            endpoint=cfg.distill_endpoint,
            timeout=cfg.distill_timeout_seconds,
            max_statements=cfg.distill_max_statements_per_passage,
            think=cfg.distill_think,
        )
        return DistillWorker(
            cfg.output_root,
            distiller,
            max_statements_per_passage=cfg.distill_max_statements_per_passage,
            on_sidecar=(embed_worker.submit if embed_worker is not None else None),
        )

    distill_worker = None
    if cfg.distill_enabled:
        try:
            distill_worker = _build_distill_worker()
            distill_worker.start()
            _print(
                f"[huske] distillation enabled — transcripts distilled to statements "
                f"({cfg.distill_model} via {cfg.distill_backend})"
            )
        except Exception as exc:
            log.warning("distill_worker_start_failed", error=str(exc))
            distill_worker = None
    state.update(distill_enabled=distill_worker is not None)

    def _on_written(path: Path) -> None:
        if embed_worker is not None:
            embed_worker.submit(str(path))
        if sync_worker is not None:
            sync_worker.submit(str(path))
        if distill_worker is not None:
            distill_worker.submit(str(path))

    def _drain_embed() -> None:
        if embed_worker is None:
            return
        while True:
            msg = embed_worker.poll_result(timeout=0.0)
            if msg is None:
                break
            if "ready" in msg:
                if msg.get("ready"):
                    on_event("info", "indexing ready — transcripts will be embedded")
                else:
                    detail = str(msg.get("error", "")).splitlines()[0]
                    on_event("warn", f"indexing unavailable: {detail}")
            elif not msg.get("ok"):
                detail = str(msg.get("error", "")).splitlines()[0]
                on_event("warn", f"indexing failed: {detail}")
            else:
                log.info("indexed", path=msg.get("path"), passages=msg.get("passages"))

    def _drain_sync() -> None:
        if sync_worker is None:
            return
        while True:
            evt = sync_worker.poll_event(timeout=0.0)
            if evt is None:
                break
            if "reconcile" in evt:
                pending = int(evt.get("reconcile", 0))
                if pending:
                    on_event("info", f"replication: catching up {pending} transcript(s)")
            elif not evt.get("ok"):
                on_event("warn", f"replication: {evt.get('error', 'push failed')}")
            else:
                log.info("replicated", rel_path=evt.get("rel_path"), status=evt.get("status"))

    def _drain_distill() -> None:
        if distill_worker is None:
            return
        while True:
            evt = distill_worker.poll_event(timeout=0.0)
            if evt is None:
                break
            if "reconcile" in evt:
                pending = int(evt.get("reconcile", 0))
                if pending:
                    on_event("info", f"distillation: catching up {pending} transcript(s)")
            elif evt.get("ok"):
                # A success clears any prior "unavailable" sticky warning.
                state.clear_warning("distill")
                log.info(
                    "distilled",
                    path=evt.get("path"),
                    statements=evt.get("statements"),
                    skipped=evt.get("skipped", False),
                )
            elif evt.get("unavailable"):
                # Daemon down / model missing — one sticky warning, not per-chunk spam.
                detail = str(evt.get("error", "")).splitlines()[0]
                state.set_warning("distill", f"distillation unavailable: {detail}")
            else:
                detail = str(evt.get("error", "")).splitlines()[0]
                on_event("warn", f"distillation failed: {detail}")

    def _on_tick() -> None:
        _drain_embed()
        _drain_sync()
        _drain_distill()

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

    def _pending_count() -> int:
        # True in-flight depth (queued + transcribing), thread-safe. Unlike
        # worker.queue_depth — whose mp.Queue.qsize() raises NotImplementedError
        # on macOS and reports 0 there — this is authoritative on every platform.
        with pending_lock:
            return len(pending_chunks)

    def on_finalized(chunk: AudioChunk) -> None:
        with pending_lock:
            pending_chunks.add(chunk.chunk_seq)
        worker.submit(chunk_to_job(chunk, cfg))
        state.update(queue_depth=_pending_count())
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

    # Distillation toggles run off the main loop: turning on probes the LLM
    # daemon (a ~seconds network call) and turning off drains the worker — either
    # would stall the ~50 ms audio drainer if run inline. A non-blocking lock
    # serialises toggles so rapid presses don't race on `distill_worker`.
    distill_toggle_lock = threading.Lock()

    def _distill_toggle_run() -> None:
        nonlocal distill_worker
        try:
            if stop_flag.is_set():
                return
            if distill_worker is not None:
                w = distill_worker
                distill_worker = None  # stop submitting before the (slow) drain
                state.update(distill_enabled=False)
                state.clear_warning("distill")
                on_event("info", "distillation off")
                w.stop(drain_timeout=15.0)
                return

            from huske.distill.health import probe_distill

            on_event("info", f"distillation: checking {cfg.distill_model}…")
            r = probe_distill(
                cfg.distill_model,
                backend=cfg.distill_backend,
                endpoint=cfg.distill_endpoint,
            )
            if not r.ok:
                msg = f"distillation unavailable: {r.detail}"
                state.set_warning("distill", msg)
                on_event("warn", msg + (f" — {r.hint}" if r.hint else ""))
                return
            if stop_flag.is_set():
                return
            try:
                worker = _build_distill_worker()
                worker.start()
            except Exception as exc:
                on_event("error", f"distillation: could not start: {exc}")
                return
            distill_worker = worker
            state.update(distill_enabled=True)
            state.clear_warning("distill")
            on_event("info", f"distillation on ({cfg.distill_model})")
        finally:
            distill_toggle_lock.release()

    def _toggle_distill() -> None:
        if not distill_toggle_lock.acquire(blocking=False):
            on_event("info", "distillation: still switching — hold on")
            return
        threading.Thread(
            target=_distill_toggle_run, name="huske-distill-toggle", daemon=True
        ).start()

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

    def _apply_mic_device(new_idx: int, new_name: str) -> bool:
        """Swap the live mic and persist the preference. Shared by the TUI
        picker and the IPC ``set_input_device`` command."""
        if not capture.swap_mic_device(new_idx):
            return False
        active_mic["name"] = new_name
        on_event("info", f"microphone → {new_name}")
        try:
            update_user_config({"input_device": new_name})
        except Exception as exc:
            on_event("warn", f"could not save mic preference: {exc}")
        return True

    def _set_input_device(arg: str | int | None) -> None:
        if arg is None:
            on_event("warn", "set_input_device requires a device name or index")
            return
        try:
            devices = list_input_devices()
        except Exception as exc:
            on_event("error", f"could not list input devices: {exc}")
            return
        if isinstance(arg, int):
            target = next((d for d in devices if d.index == arg), None)
        else:
            target = match_input_device(devices, arg)
        if target is None:
            on_event("warn", f"input device not found: {arg!r}")
            return
        if target.index == capture.mic_device_index:
            return
        if not _apply_mic_device(target.index, target.name):
            on_event("warn", f"could not switch microphone to {target.name}")

    def _broadcast_devices() -> None:
        if server is None:
            return
        try:
            devices = list_input_devices()
        except Exception as exc:
            on_event("error", f"could not list input devices: {exc}")
            return
        server.broadcast_devices(
            DeviceList(
                devices=tuple(
                    InputDeviceEntry(
                        index=d.index,
                        name=d.name,
                        channels=d.max_input_channels,
                        sample_rate=d.default_samplerate,
                    )
                    for d in devices
                ),
                current_index=capture.mic_device_index,
            )
        )

    commands = CommandChannel()
    dispatch: dict[Command, Callable[[], None]] = {
        Command.PAUSE_RESUME: _toggle_pause,
        Command.TOGGLE_SCREENSHOTS: _toggle_screenshots,
        Command.TOGGLE_DISTILL: _toggle_distill,
        Command.STOP: _stop,
        Command.OPEN_TRANSCRIPTS: _open_transcripts,
        Command.OPEN_LATEST_TRANSCRIPT: _open_latest_transcript,
    }

    def _pump_commands() -> None:
        for cmd, arg in commands.drain():
            if cmd is Command.SET_INPUT_DEVICE:
                _set_input_device(arg)
            elif cmd is Command.REQUEST_DEVICES:
                _broadcast_devices()
            else:
                handler = dispatch.get(cmd)
                if handler is not None:
                    handler()

    server: ControlServer | None = None
    helper_proc: subprocess.Popen[bytes] | None = None
    # Two ways to get a control socket:
    # - An external UI (the native macOS app) passes ``--control-socket PATH``:
    #   serve the protocol there and spawn no helper — the app owns presentation.
    # - Otherwise the socket exists solely to drive the menu bar helper, so it
    #   is only started when the menu bar is enabled. With `--no-menu-bar` we
    #   skip the whole IPC server — no helper process (~50-80 MB), no accept
    #   thread, and no socket file — the lightest possible recording footprint.
    external_socket = cfg.control_socket is not None
    if external_socket or (sys.platform == "darwin" and cfg.menu_bar_enabled):
        if cfg.control_socket is not None:
            socket_path = cfg.control_socket
        else:
            socket_dir = Path.home() / "Library" / "Application Support" / "huske"
            socket_path = (
                socket_dir / f"control-{paths.session_id_short(session.session_id)}.sock"
            )
        server = ControlServer(socket_path, commands, log)
        try:
            server.start()
            log.info("ipc_server_started", socket=str(socket_path))
        except OSError as exc:
            log.warning("ipc_server_failed", error=str(exc))
            server = None

        if server is not None and not external_socket:
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
        snap = build_control_snapshot(
            state,
            session_id=session.session_id,
            session_started_at=session.started_at,
            output_root=cfg.output_root,
            input_device_name=active_mic["name"],
        )
        if snap == last_snap:
            return
        last_snap = snap
        server.broadcast_state(snap)

    def _session_loop() -> None:
        # Phase 1: normal recording — runs until Ctrl+C / SIGTERM sets stop_flag.
        _main_loop(
            cfg, state, rotator, capture, worker, stop_flag, log,
            on_result,
            screenshot_status=_screenshot_status,
            pump_commands=_pump_commands,
            publish_state=_publish_state,
            on_written=_on_written,
            on_tick=_on_tick,
            pending_count=_pending_count,
        )

        # Phase 2: stopping. Keep publishing state while we drain so the app
        # and menu bar helper show the countdown.
        state.update(recording=False, paused=False, stopping=True)
        _publish_state()

        on_event("info", "stopping capture…")
        capture.stop()
        if screenshotter is not None:
            screenshotter.stop()
            _sync_screenshot_state()
            on_event("info", f"screenshots saved: {screenshotter.captures}")
        rotator.finalize_current()

        pending_count = _pending_count()
        on_event("info", f"draining {pending_count} transcription(s)…")
        state.update(queue_depth=pending_count)

        deadline = time.monotonic() + 600.0  # 10 min hard cap
        last_publish = 0.0
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
                    tp = Path(result["transcript_path"])
                    state.update(last_saved=tp)
                    on_event("info", f"chunk {seq:03d} → {tp.name}")
                    _on_written(tp)
                else:
                    on_event(
                        "error",
                        f"chunk {seq:03d} failed: {result['error'].splitlines()[0]}",
                    )
            elif not worker.alive:
                on_event("error", "worker exited unexpectedly")
                break

            now = time.monotonic()
            if now - last_publish >= 0.25:
                _on_tick()
                state.update(queue_depth=_pending_count())
                _publish_state()
                last_publish = now

        # Final publish so subscribers see "0 pending" before we tear down.
        state.update(queue_depth=0)
        _publish_state()

    try:
        _print(f"[huske] recording — Ctrl+C to stop. transcripts → {cfg.output_root}")
        _session_loop()
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
        if distill_worker is not None:
            # Stop distillation first: draining it hands each remaining sidecar to
            # the embed worker (via on_sidecar) before we drain that worker below,
            # so this session's last statements still get embedded. The LLM is
            # slow, so allow a little longer; daemon-thread leftovers die on exit.
            distill_worker.stop(drain_timeout=15.0)
        if embed_worker is not None:
            # SENTINEL is FIFO after queued paths, so any transcripts written
            # during drain still get indexed before the worker exits.
            embed_worker.stop(drain_timeout=10.0)
        if sync_worker is not None:
            sync_worker.stop(drain_timeout=10.0)
        if sync_outbox is not None:
            sync_outbox.close()
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
    screenshot_status: Callable[[], tuple[bool, int, datetime | None]] | None = None,
    pump_commands: Callable[[], None] | None = None,
    publish_state: Callable[[], None] | None = None,
    on_written: Callable[[Path], None] | None = None,
    on_tick: Callable[[], None] | None = None,
    pending_count: Callable[[], int] | None = None,
) -> None:
    """Run the asyncio-free main loop: poll worker results, refresh state,
    publish control-plane snapshots, watch the capture heartbeat."""

    def _depth() -> int:
        return pending_count() if pending_count is not None else worker.queue_depth

    while not stop_flag.is_set():
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
                state.update(last_saved=tp, queue_depth=_depth())
                state.push_event("info", f"chunk {seq:03d} → {tp.name}")
                if on_written is not None:
                    on_written(tp)
            else:
                state.push_event(
                    "error",
                    f"chunk {seq:03d} failed: {result['error'].splitlines()[0]}",
                )

        if on_tick is not None:
            on_tick()

        # Render-state refresh (feeds the control-plane snapshot).
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
            queue_depth=_depth(),
            **screenshot_fields,
        )

        if publish_state is not None:
            publish_state()

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
    report = RecoveryReport()
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
