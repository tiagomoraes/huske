"""Typer CLI shell — subcommands wire up below as they land."""

from __future__ import annotations

from pathlib import Path

import typer

from huske import __version__

app = typer.Typer(
    name="huske",
    help="Headless audio capture, local transcription, and private transcript sync.",
    no_args_is_help=False,
    add_completion=False,
)


def _version_callback(value: bool) -> None:
    if value:
        typer.echo(f"huske {__version__}")
        raise typer.Exit(0)


@app.callback(invoke_without_command=True)
def main(
    ctx: typer.Context,
    version: bool = typer.Option(
        False,
        "--version",
        callback=_version_callback,
        is_eager=True,
        help="Show version and exit.",
    ),
) -> None:
    """huske — always-on audio recorder + local transcription."""
    from huske.proctitle import set_process_title
    from huske.update_check import notify_if_outdated

    # Name the OS process "huske" (Activity Monitor / ps) instead of the bare
    # Python interpreter. The menu bar helper names itself "huske-menubar" in its
    # own command, and the worker subprocesses set their titles in their
    # entrypoints, so they are skipped here.
    if ctx.invoked_subcommand != "menubar":
        set_process_title("huske")

    notify_if_outdated()
    if ctx.invoked_subcommand is None:
        # Default subcommand is `run`.
        ctx.invoke(run)


@app.command()
def run(
    chunk_minutes: float | None = typer.Option(
        None,
        "--chunk-minutes",
        "-c",
        min=0.1,
        max=60.0,
        help="Maximum chunk length in minutes (a safety cap; chunks normally "
        "close on a pause in speech — see --silence-split). Default 30.",
    ),
    output_root: Path | None = typer.Option(None, "--output-root"),
    audio_root: Path | None = typer.Option(None, "--audio-root"),
    asr_engine: str | None = typer.Option(
        None,
        "--asr-engine",
        help="Transcription backend: parakeet (default, silence-robust, "
        "multilingual but infers the language per window and cannot be pinned) "
        "or whisper (mlx-whisper; the only engine that enforces --language).",
    ),
    asr_model: str | None = typer.Option(
        None,
        "--asr-model",
        help="Transcription model for this session: an id from `huske models`, a "
        "Hugging Face repo, or a local folder (overrides the config).",
    ),
    parakeet_model: str | None = typer.Option(
        None,
        "--parakeet-model",
        help="Parakeet model id when --asr-engine=parakeet "
        "(default mlx-community/parakeet-tdt-0.6b-v3).",
    ),
    speech_gated: bool | None = typer.Option(
        None,
        "--speech-gated/--no-speech-gated",
        help="Segment audio on real pauses in speech instead of a fixed clock "
        "(on by default). --no-speech-gated restores fixed-interval rotation.",
    ),
    silence_split: float | None = typer.Option(
        None,
        "--silence-split",
        min=2.0,
        max=600.0,
        help="Seconds of continuous silence that close the current chunk "
        "(default 60).",
    ),
    echo_cancel: bool | None = typer.Option(
        None,
        "--echo-cancel/--no-echo-cancel",
        help="Cancel system audio that bleeds into the mic over speakers "
        "(WebRTC AEC3 against the system channel) before transcription. On "
        "by default; self-gating (no effect with headphones).",
    ),
    echo_dedup: str | None = typer.Option(
        None,
        "--echo-dedup",
        help="Remove a residual mic copy of a system line (full or partial): "
        "drop (default), annotate, or off.",
    ),
    model: str | None = typer.Option(None, "--model"),
    compute_type: str | None = typer.Option(None, "--compute-type"),
    device: str | None = typer.Option(None, "--device"),
    language: str | None = typer.Option(None, "--language"),
    input_device: str | None = typer.Option(None, "--input-device"),
    # None = "not given": a False default here would always override a
    # `keep_audio = true` in the config file.
    keep_audio: bool | None = typer.Option(None, "--keep-audio/--no-keep-audio"),
    keep_audio_format: str | None = typer.Option(
        None,
        "--keep-audio-format",
        help="Format for retained audio when --keep-audio is set: opus (default, "
        "smallest), flac (lossless), or wav (uncompressed).",
    ),
    screenshots: bool | None = typer.Option(
        None,
        "--screenshots/--no-screenshots",
        help="Capture a JPEG of every display every N seconds (off by default).",
    ),
    screenshot_interval: float | None = typer.Option(
        None,
        "--screenshot-interval",
        min=1.0,
        max=3600.0,
        help="Seconds between screenshots (default 60, minimum 1).",
    ),
    screenshot_max_dimension: int | None = typer.Option(
        None,
        "--screenshot-max-dimension",
        min=0,
        max=10000,
        help="Downscale each screenshot so its long edge is at most N px "
        "(default 1568; 0 disables resize). Never upscales.",
    ),
    screenshot_quality: int | None = typer.Option(
        None,
        "--screenshot-quality",
        min=1,
        max=100,
        help="JPEG quality for screenshots, 1-100 (default 60).",
    ),
    screenshots_root: Path | None = typer.Option(
        None, "--screenshots-root", help="Where screenshots are written."
    ),
    idle_unload: bool | None = typer.Option(
        None,
        "--idle-unload/--no-idle-unload",
        help="Unload the Whisper model from memory between chunks to lower idle "
        "RAM (frees ~150 MB to 3 GB depending on model size). The next chunk pays "
        "a few-second reload from the local cache. On by default; pass "
        "--no-idle-unload to keep the model warm.",
    ),
    distill: bool | None = typer.Option(
        None,
        "--distill/--no-distill",
        help="Correct typos and ASR errors in each finished transcript with "
        "huske's tiny built-in local LLM (downloads on first use). Off by default.",
    ),
    distill_model: str | None = typer.Option(
        None,
        "--distill-model",
        help="Correction model: a Hugging Face repo for the built-in MLX "
        "backend (default mlx-community/Qwen3.5-0.8B-4bit) or an Ollama tag "
        "when distill_backend = 'ollama'.",
    ),
    distill_auto_manage: bool | None = typer.Option(
        None,
        "--distill-auto-manage/--no-distill-auto-manage",
        help="When distillation turns on, let huske start the local Ollama daemon "
        "and pull the model if missing (never installs Ollama itself). On by default.",
    ),
    config_path: Path | None = typer.Option(None, "--config"),
    log_level: str = typer.Option("INFO", "--log-level"),
    no_ui: bool = typer.Option(
        False,
        "--no-ui",
        hidden=True,
        help="Deprecated no-op: huske run is always headless now (the Rich "
        "terminal panel was removed in favor of the macOS app). Kept so "
        "older launchers that pass it keep working.",
    ),
    menu_bar: bool | None = typer.Option(
        None,
        "--menu-bar/--no-menu-bar",
        help="Show a macOS menu bar icon while recording (macOS only). "
        "Defaults to the config file value, or true if unset.",
    ),
    system_audio_backend: str | None = typer.Option(
        None,
        "--system-audio-backend",
        help="System audio backend: auto (default), tap, sck, off.",
    ),
    control_socket: Path | None = typer.Option(
        None,
        "--control-socket",
        help="Serve the JSON-line control protocol at this Unix socket path "
        "for an external UI (used by the native macOS app). Implies no "
        "bundled menu bar helper.",
    ),
) -> None:
    """Start a headless recording session (drive it from Huske.app or the menu bar)."""
    from huske.run_loop import run_session

    cli_overrides = _collect_overrides(
        chunk_minutes=chunk_minutes,
        output_root=output_root,
        audio_root=audio_root,
        asr_engine=asr_engine,
        asr_model=asr_model,
        parakeet_model=parakeet_model,
        speech_gated=speech_gated,
        silence_split_seconds=silence_split,
        echo_cancel=echo_cancel,
        echo_dedup=echo_dedup,
        model=model,
        compute_type=compute_type,
        device=device,
        language=language,
        input_device=input_device,
        keep_audio=keep_audio,
        keep_audio_format=keep_audio_format,
        whisper_idle_unload=idle_unload,
        distill_enabled=distill,
        distill_model=distill_model,
        distill_auto_manage=distill_auto_manage,
        screenshots_enabled=screenshots,
        screenshots_interval_seconds=screenshot_interval,
        screenshots_max_dimension=screenshot_max_dimension,
        screenshots_jpeg_quality=screenshot_quality,
        screenshots_root=screenshots_root,
        log_level=log_level,
        no_ui=no_ui,
        menu_bar_enabled=menu_bar,
        system_audio_backend=system_audio_backend,
        control_socket=control_socket,
    )
    raise typer.Exit(run_session(config_path=config_path, cli_overrides=cli_overrides))


@app.command()
def menubar(
    attach: Path = typer.Option(..., "--attach", help="Path to a huske control socket."),
    style: str = typer.Option(
        "text",
        "--style",
        help="Label style for the menu bar item: 'text' (default, shows 'huske') or 'icon' (logo).",
    ),
) -> None:
    """Render the menu bar helper attached to a running huske session (macOS only)."""
    from huske.menubar import run_helper
    from huske.proctitle import set_process_title

    # The callback skips this subcommand, so name the helper here instead — it
    # coexists with the accessory NSApplication / status-bar item (verified).
    set_process_title("huske-menubar")

    if style not in {"text", "icon"}:
        typer.secho(f"invalid --style: {style!r} (expected 'text' or 'icon')", fg=typer.colors.RED, err=True)
        raise typer.Exit(2)
    raise typer.Exit(run_helper(attach, style=style))


@app.command()
def recover(
    output_root: Path | None = typer.Option(None, "--output-root"),
    audio_root: Path | None = typer.Option(None, "--audio-root"),
    model: str | None = typer.Option(None, "--model"),
    compute_type: str | None = typer.Option(None, "--compute-type"),
    device: str | None = typer.Option(None, "--device"),
    language: str | None = typer.Option(None, "--language"),
    config_path: Path | None = typer.Option(None, "--config"),
    log_level: str = typer.Option("INFO", "--log-level"),
) -> None:
    """Process orphaned audio chunks from prior runs without recording."""
    from huske.run_loop import run_recover

    cli_overrides = _collect_overrides(
        output_root=output_root,
        audio_root=audio_root,
        model=model,
        compute_type=compute_type,
        device=device,
        language=language,
        log_level=log_level,
    )
    raise typer.Exit(run_recover(config_path=config_path, cli_overrides=cli_overrides))


@app.command()
def doctor(
    input_device: str | None = typer.Option(None, "--input-device"),
    system_audio_backend: str | None = typer.Option(
        None,
        "--system-audio-backend",
        help="System audio backend to validate: auto, tap, sck, off.",
    ),
    config_path: Path | None = typer.Option(None, "--config"),
    json_output: bool = typer.Option(False, "--json"),
) -> None:
    """Validate audio devices, model availability, and write paths."""
    from huske.doctor import run_doctor

    cli_overrides = _collect_overrides(
        input_device=input_device,
        system_audio_backend=system_audio_backend,
    )
    raise typer.Exit(
        run_doctor(
            config_path=config_path,
            cli_overrides=cli_overrides,
            json_output=json_output,
        )
    )


@app.command("echo-test")
def echo_test(
    input_device: str | None = typer.Option(
        None, "--input-device", help="Microphone to test (default: system default)."
    ),
    canceller: str = typer.Option(
        "auto", "--canceller", help="auto (WebRTC AEC3), webrtc, or coherence."
    ),
    json_output: bool = typer.Option(False, "--json"),
) -> None:
    """Play a short phrase on the speakers and measure echo cancellation.

    Captures mic + system audio the way `huske run` does, runs the same echo
    canceller the transcriber uses, and reports how much speaker bleed it
    removed. Nothing is saved. Needs Microphone + System Audio Recording access.
    """
    import json as _json

    from huske.capture.echo_test import run_echo_test

    if canceller not in ("auto", "webrtc", "coherence"):
        typer.secho(f"invalid --canceller: {canceller!r}", fg=typer.colors.RED, err=True)
        raise typer.Exit(1)
    if not json_output:
        typer.echo("Playing a short phrase through your speakers (~8 s)…")
    try:
        result = run_echo_test(mic_name=input_device, method=canceller)
    except Exception as exc:
        if json_output:
            typer.echo(_json.dumps({"ok": False, "error": str(exc)}))
        else:
            typer.secho(f"echo test failed: {exc}", fg=typer.colors.RED, err=True)
        raise typer.Exit(2) from exc
    if json_output:
        typer.echo(_json.dumps({"ok": True, **result.to_json()}))
        return
    typer.echo(f"  output      {result.output_device or '?'}")
    typer.echo(f"  microphone  {result.mic_device or 'default'}")
    typer.echo(f"  capture     {result.capture_mode} · canceller {result.method}")
    if result.echo_present:
        typer.echo(
            f"  echo        {result.mic_level_db:.1f} dB → {result.residual_level_db:.1f} dB"
            f"  (delay {result.echo_delay_ms} ms)"
        )
    typer.secho(f"  {result.verdict}", fg=typer.colors.GREEN if result.erle_db >= 15 or not result.echo_present else typer.colors.YELLOW)


@app.command()
def devices(
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """List microphone input devices (● marks the one huske will use)."""
    from huske.config_tool import list_devices

    raise typer.Exit(list_devices(config_path=config_path, json_output=json_output))


# ---------------------------------------------------------------------------
# Config inspection / editing (used by humans and the native macOS app)
# ---------------------------------------------------------------------------

config_app = typer.Typer(
    name="config",
    help="Inspect and edit the huske config file (~/.config/huske/config.toml).",
    no_args_is_help=True,
    add_completion=False,
)
app.add_typer(config_app)


@config_app.command("show")
def config_show(
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Print the effective configuration (defaults merged with the file)."""
    from huske.config_tool import show_config

    raise typer.Exit(show_config(config_path=config_path, json_output=json_output))


@config_app.command("set")
def config_set(
    key: str = typer.Argument(..., help="Config key, e.g. input_device."),
    value: str = typer.Argument(
        ..., help="New value. JSON scalars are typed (true, 0.5); anything else is a string."
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Validate and persist one config key (Pydantic-checked before writing)."""
    from huske.config_tool import set_config_value

    raise typer.Exit(set_config_value(key, value, config_path=config_path))


@config_app.command("unset")
def config_unset(
    key: str = typer.Argument(..., help="Config key to remove (reverts to default)."),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Remove one key from the config file, reverting to the built-in default."""
    from huske.config_tool import unset_config_value

    raise typer.Exit(unset_config_value(key, config_path=config_path))


# ---------------------------------------------------------------------------
# Optional local transcript derivations
# ---------------------------------------------------------------------------


@app.command()
def distill(
    output_root: Path | None = typer.Option(None, "--output-root"),
    model: str | None = typer.Option(
        None, "--model", help="Correct with this LLM tag (e.g. qwen3.5:0.8b), overriding config."
    ),
    force: bool = typer.Option(
        False, "--force", help="Re-distill even transcripts whose content is unchanged."
    ),
    low_impact: bool | None = typer.Option(
        None,
        "--low-impact/--fast",
        help="Throttle the backfill (lower CPU priority). On by default; --fast for full speed.",
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Correct ASR errors in transcripts with a tiny local LLM.

    Rewrites each canonical ``.md`` in place after snapshotting the raw ASR
    to ``<name>.asr.txt``. Uses the built-in 0.8B MLX model by default
    (downloads on first use); set ``distill_backend = "ollama"`` to delegate
    to an Ollama daemon instead.
    """
    from huske.distill.runner import run_distill

    cli_overrides = _collect_overrides(output_root=output_root, distill_model=model)
    raise typer.Exit(
        run_distill(
            config_path=config_path,
            cli_overrides=cli_overrides,
            force=force,
            low_impact=low_impact,
        )
    )


# ---------------------------------------------------------------------------
# Transcript cleanup (LLM post-processing) and languages
# ---------------------------------------------------------------------------

llm_app = typer.Typer(
    name="llm",
    help="Set up transcript cleanup with a language model: Apple Intelligence, a local "
    "model, or a cloud provider with your API key.",
    no_args_is_help=True,
    add_completion=False,
)
app.add_typer(llm_app)
llm_key_app = typer.Typer(
    name="key",
    help="API keys for cloud providers, stored in the macOS Keychain (never in the config).",
    no_args_is_help=True,
    add_completion=False,
)
llm_app.add_typer(llm_key_app)


@llm_app.command("status")
def llm_status(
    backend: str | None = typer.Option(
        None, "--backend", help="Check this backend instead of the configured one."
    ),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Where cleanup runs, whether it can right now, and what to do if not."""
    from huske.distill.llm_cli import run_status

    raise typer.Exit(run_status(json_output=json_output, config_path=config_path, backend=backend))


@llm_app.command("models")
def llm_models(
    backend: str | None = typer.Option(None, "--backend", help="Provider to ask (default: configured)."),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """List the models a provider offers (uses your stored key for cloud providers)."""
    from huske.distill.llm_cli import run_models

    raise typer.Exit(run_models(json_output=json_output, config_path=config_path, backend=backend))


@llm_app.command("allow-cloud")
def llm_allow_cloud(
    yes: bool = typer.Option(False, "--yes", help="Confirm without the interactive question."),
    revoke: bool = typer.Option(False, "--revoke", help="Stop sending transcripts off this Mac."),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Allow sending transcript text to the configured provider's host (asks first)."""
    from huske.distill.llm_cli import run_allow_cloud

    raise typer.Exit(
        run_allow_cloud(yes=yes, revoke=revoke, json_output=json_output, config_path=config_path)
    )


@llm_app.command("test")
def llm_test(
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Clean up a short synthetic sample with the configured backend."""
    from huske.distill.llm_cli import run_test

    raise typer.Exit(run_test(json_output=json_output, config_path=config_path))


@llm_key_app.command("set")
def llm_key_set(
    provider: str = typer.Argument(..., help="openai, anthropic, openrouter or openai_compatible."),
    json_output: bool = typer.Option(False, "--json"),
) -> None:
    """Save an API key (prompted, or read from stdin — never pass it as an argument)."""
    from huske.distill.llm_cli import run_key_set

    raise typer.Exit(run_key_set(provider, json_output=json_output))


@llm_key_app.command("remove")
def llm_key_remove(
    provider: str = typer.Argument(..., help="openai, anthropic, openrouter or openai_compatible."),
    json_output: bool = typer.Option(False, "--json"),
) -> None:
    """Delete a stored API key."""
    from huske.distill.llm_cli import run_key_remove

    raise typer.Exit(run_key_remove(provider, json_output=json_output))


@llm_key_app.command("list")
def llm_key_list(json_output: bool = typer.Option(False, "--json")) -> None:
    """Which providers have a key saved (never prints the keys)."""
    from huske.distill.llm_cli import run_key_list

    raise typer.Exit(run_key_list(json_output=json_output))


models_app = typer.Typer(
    name="models",
    help="See, choose, download and try transcription models. Without a subcommand: "
    "the list.",
    invoke_without_command=True,
    add_completion=False,
)
app.add_typer(models_app)


@models_app.callback()
def models_main(
    ctx: typer.Context,
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """List the transcription models: which is in use, languages, size, speed."""
    if ctx.invoked_subcommand is None:
        from huske.transcribe.models_cli import run_list

        raise typer.Exit(run_list(json_output=json_output, config_path=config_path))


@models_app.command("list")
def models_list(
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """List the transcription models (same as `huske models`)."""
    from huske.transcribe.models_cli import run_list

    raise typer.Exit(run_list(json_output=json_output, config_path=config_path))


@models_app.command("info")
def models_info(
    model: str = typer.Argument(..., help="Model id, Hugging Face repo, or local folder."),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Everything about one model: languages, dictionary support, size, speed."""
    from huske.transcribe.models_cli import run_info

    raise typer.Exit(run_info(model, json_output=json_output, config_path=config_path))


@models_app.command("use")
def models_use(
    model: str | None = typer.Argument(
        None, help="Model id, Hugging Face repo, or local folder. Omit to pick from a list."
    ),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Choose the transcription model (applies from the next session)."""
    from huske.transcribe.models_cli import run_use

    raise typer.Exit(run_use(model, json_output=json_output, config_path=config_path))


@models_app.command("download")
def models_download(
    model: str | None = typer.Argument(None, help="Model to fetch (default: the one in use)."),
    json_output: bool = typer.Option(
        False, "--json", help="Stream progress as JSON lines (for Huske.app)."
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Download a model now instead of on first use."""
    from huske.transcribe.models_cli import run_download

    raise typer.Exit(run_download(model, json_output=json_output, config_path=config_path))


@models_app.command("convert")
def models_convert(
    repo: str = typer.Argument(
        ..., help="A Whisper fine-tune on Hugging Face in the transformers layout."
    ),
    name: str | None = typer.Option(None, "--name", help="Folder name under models_root."),
    json_output: bool = typer.Option(
        False, "--json", help="Stream progress as JSON lines (for Huske.app)."
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Convert a Hugging Face Whisper fine-tune (e.g. a Portuguese one) to run in Huske."""
    from huske.transcribe.models_cli import run_convert

    raise typer.Exit(
        run_convert(repo, name=name, json_output=json_output, config_path=config_path)
    )


@models_app.command("try")
def models_try(
    model: str | None = typer.Argument(None, help="Model to try (default: the one in use)."),
    audio: Path | None = typer.Option(
        None, "--audio", help="Audio file to transcribe (default: a synthetic sample)."
    ),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Transcribe a sample with a model and show how fast it runs on this Mac."""
    from huske.transcribe.models_cli import run_try

    raise typer.Exit(
        run_try(model, audio=audio, json_output=json_output, config_path=config_path)
    )


@app.command("languages")
def languages_cmd(json_output: bool = typer.Option(False, "--json")) -> None:
    """Language codes for `language`, and what each engine does with them."""
    from huske.distill.llm_cli import run_languages

    raise typer.Exit(run_languages(json_output=json_output))


@app.command("export")
def export_cmd(
    export_root: Path | None = typer.Option(
        None, "--export-root", help="Where to write the day files (default ~/huske/export)."
    ),
    statements_only: bool = typer.Option(
        False,
        "--statements-only",
        help="Write only the distilled key points, omitting the verbatim transcript.",
    ),
    since: str | None = typer.Option(
        None, "--since", help="Only export days on or after this YYYY-MM-DD."
    ),
    force: bool = typer.Option(
        False, "--force", help="Rewrite days whose source content is unchanged."
    ),
    output_root: Path | None = typer.Option(None, "--output-root"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Export one Markdown file per day, for tools that can't speak MCP.

    A Claude Project, NotebookLM, Obsidian, or a synced Drive/Dropbox folder
    reads files, not MCP — and huske natively writes many small files per day,
    which such a tool cannot rank. This collapses each day into one document,
    distilled key points first.

    Syncing this folder to a third-party cloud puts plaintext transcripts there.
    Huske's managed cloud-sync path publishes the canonical transcript tree to
    the private Git repository configured in the app.
    """
    from huske.export import run_export

    overrides = _collect_overrides(output_root=output_root)
    raise typer.Exit(
        run_export(
            config_path=config_path,
            cli_overrides=overrides,
            export_root=export_root,
            statements_only=statements_only,
            force=force,
            since=since,
        )
    )


@app.command()
def sync(
    output_root: Path | None = typer.Option(None, "--output-root"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Publish every transcript not yet present in the configured Git repository."""
    from huske.sync.runner import run_sync

    overrides = _collect_overrides(output_root=output_root)
    raise typer.Exit(run_sync(config_path=config_path, cli_overrides=overrides))


# ---------------------------------------------------------------------------
# Engine inbox: external recordings (iPhone, audio files) → transcripts
# ---------------------------------------------------------------------------

inbox_app = typer.Typer(
    name="inbox",
    help="Hand recordings that did not come from live capture to the engine "
    "for transcription (see `huske import` for the one-step version).",
    no_args_is_help=True,
    add_completion=False,
)
app.add_typer(inbox_app)


@inbox_app.command("add")
def inbox_add(
    file: Path = typer.Argument(..., help="Audio file (m4a, caf, wav, flac, mp3, aiff, ogg, …)."),
    item_id: str | None = typer.Option(
        None,
        "--id",
        help="Stable id (1-64 of A-Z a-z 0-9 . _ -). Re-adding an id is a no-op. "
        "Default: a hash of the file's contents.",
    ),
    title: str | None = typer.Option(None, "--title", help="Recorded in the transcripts."),
    device: str | None = typer.Option(None, "--device", help="Recording device name."),
    origin: str = typer.Option("file", "--origin", help="phone or file (default)."),
    started_at: str | None = typer.Option(
        None,
        "--started-at",
        help="ISO 8601 recording start. Default: the file's modification time "
        "minus its duration.",
    ),
    duration: float | None = typer.Option(
        None, "--duration", help="Duration in seconds, if known (probed otherwise)."
    ),
    move: bool = typer.Option(False, "--move", help="Move FILE into the inbox instead of copying it."),
    language: str | None = typer.Option(
        None, "--language", help="Spoken language of this recording (default: the config's)."
    ),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Stage FILE as an inbox item and print its status."""
    from huske.inbox.runner import run_inbox_add

    raise typer.Exit(
        run_inbox_add(
            file,
            item_id=item_id,
            title=title,
            device=device,
            origin=origin,
            started_at=started_at,
            duration=duration,
            move=move,
            language=language,
            json_output=json_output,
            config_path=config_path,
        )
    )


@inbox_app.command("process")
def inbox_process(
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Transcribe every queued (or retryable failed) item now, then exit.

    Returns immediately with deferred_to_engine when a running `huske run`
    holds the inbox: it transcribes the queue itself.
    """
    from huske.inbox.runner import run_inbox_process

    raise typer.Exit(run_inbox_process(json_output=json_output, config_path=config_path))


@inbox_app.command("status")
def inbox_status(
    ids: list[str] | None = typer.Argument(None, help="Item ids (default: every item)."),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Show inbox items, newest first."""
    from huske.inbox.runner import run_inbox_status

    raise typer.Exit(
        run_inbox_status(ids or None, json_output=json_output, config_path=config_path)
    )


@inbox_app.command("retry")
def inbox_retry(
    ids: list[str] = typer.Argument(..., help="Failed item ids to re-queue."),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Re-queue failed items (resets their 3-attempt budget)."""
    from huske.inbox.runner import run_inbox_retry

    raise typer.Exit(run_inbox_retry(ids, json_output=json_output, config_path=config_path))


@app.command("import")
def import_cmd(
    files: list[Path] = typer.Argument(..., help="Audio files to transcribe."),
    title: str | None = typer.Option(None, "--title"),
    started_at: str | None = typer.Option(
        None, "--started-at", help="ISO 8601 recording start (default: from the file)."
    ),
    language: str | None = typer.Option(
        None,
        "--language",
        help="Spoken language of these files (e.g. pt), overriding the config. "
        "Pinned on whisper; a hint on parakeet.",
    ),
    json_output: bool = typer.Option(False, "--json"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Transcribe audio files into ordinary transcripts (inbox add + process)."""
    from huske.inbox.runner import run_import

    raise typer.Exit(
        run_import(
            list(files),
            title=title,
            started_at=started_at,
            language=language,
            json_output=json_output,
            config_path=config_path,
        )
    )


# ---------------------------------------------------------------------------
# Autostart (macOS LaunchAgent)
# ---------------------------------------------------------------------------

autostart_app = typer.Typer(
    name="autostart",
    help="Manage the macOS LaunchAgent that runs huske on login.",
    no_args_is_help=True,
    add_completion=False,
)
app.add_typer(autostart_app)


def _autostart_guard() -> None:
    """Print a friendly error and exit if not on macOS."""
    from huske.agent import UnsupportedPlatformError

    try:
        from huske.agent import _ensure_macos

        _ensure_macos()
    except UnsupportedPlatformError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(2) from exc


@autostart_app.command("install")
def autostart_install(
    config_path: Path | None = typer.Option(
        None, "--config", help="Path to a huske config.toml passed through to `huske run`."
    ),
    log_level: str = typer.Option("INFO", "--log-level"),
    keep_alive: bool = typer.Option(
        True,
        "--keep-alive/--no-keep-alive",
        help="Auto-restart on crash (clean exits stay stopped). Default: on.",
    ),
    force: bool = typer.Option(
        False, "--force", help="Overwrite an existing plist."
    ),
) -> None:
    """Install and load the LaunchAgent so huske starts at login."""
    _autostart_guard()
    from huske.agent import LOG_ERR, LOG_OUT, install_agent

    try:
        path = install_agent(
            config_path=config_path,
            log_level=log_level,
            keep_alive=keep_alive,
            force=force,
        )
    except FileExistsError as exc:
        typer.secho(str(exc), fg=typer.colors.YELLOW, err=True)
        raise typer.Exit(1) from exc
    except RuntimeError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc

    typer.secho(f"✓ Wrote {path}", fg=typer.colors.GREEN)
    typer.secho("✓ Loaded into launchd (will start at next login)", fg=typer.colors.GREEN)
    typer.echo("")
    typer.echo("Logs:")
    typer.echo(f"  stdout → {LOG_OUT}")
    typer.echo(f"  stderr → {LOG_ERR}")
    typer.echo("")
    typer.echo("Next steps:")
    typer.echo(
        "  1. macOS will prompt for Microphone and Screen Recording access the"
    )
    typer.echo(
        "     first time the agent records. Approve both in System Settings"
    )
    typer.echo("     → Privacy & Security.")
    typer.echo("  2. Run `huske autostart status` to confirm it's running.")
    typer.echo("  3. The agent now starts automatically at every login.")


@autostart_app.command("uninstall")
def autostart_uninstall() -> None:
    """Bootout the LaunchAgent and remove the plist."""
    _autostart_guard()
    from huske.agent import uninstall_agent

    try:
        removed = uninstall_agent()
    except RuntimeError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc

    if removed:
        typer.secho("✓ Removed LaunchAgent.", fg=typer.colors.GREEN)
    else:
        typer.echo("Nothing to remove (was not installed).")


@autostart_app.command("status")
def autostart_status() -> None:
    """Show whether the LaunchAgent is installed and running."""
    _autostart_guard()
    from huske.agent import agent_status

    status = agent_status()

    def _yes_no(value: bool) -> str:
        return "yes" if value else "no"

    typer.echo("huske autostart")
    typer.echo(f"  installed:  {_yes_no(status.installed)}  ({status.plist_path})")
    typer.echo(f"  loaded:     {_yes_no(status.loaded)}")
    if status.pid is not None:
        typer.echo(f"  pid:        {status.pid}")
    if status.last_exit_code is not None:
        typer.echo(f"  last exit:  {status.last_exit_code}")
    typer.echo(f"  stdout log: {status.log_out}")
    typer.echo(f"  stderr log: {status.log_err}")

    raise typer.Exit(0 if status.installed and status.loaded else 1)


@autostart_app.command("start")
def autostart_start() -> None:
    """Kickstart the agent now (no-op if already running)."""
    _autostart_guard()
    from huske.agent import LAUNCHD_LABEL, start_agent

    try:
        start_agent()
    except RuntimeError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc
    typer.secho(f"✓ Kickstarted {LAUNCHD_LABEL}.", fg=typer.colors.GREEN)


@autostart_app.command("stop")
def autostart_stop() -> None:
    """Stop the agent (sends SIGTERM)."""
    _autostart_guard()
    from huske.agent import LAUNCHD_LABEL, stop_agent

    try:
        stopped = stop_agent()
    except RuntimeError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc
    if stopped:
        typer.secho(f"✓ Sent SIGTERM to {LAUNCHD_LABEL}.", fg=typer.colors.GREEN)
    else:
        typer.echo(f"{LAUNCHD_LABEL} is already stopped.")


def _collect_overrides(**kwargs: object) -> dict[str, object]:
    # When `ctx.invoke(run)` is used as a default subcommand, Typer passes the
    # raw OptionInfo descriptor objects instead of resolved values for parameters
    # the user did not explicitly set. These must be treated as "not provided" —
    # the same as None — so the config file and field defaults win.
    from typer.models import ArgumentInfo, OptionInfo

    return {
        k: v
        for k, v in kwargs.items()
        if v is not None and not isinstance(v, (OptionInfo, ArgumentInfo))
    }
