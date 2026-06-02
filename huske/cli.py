"""Typer CLI shell — subcommands wire up below as they land."""

from __future__ import annotations

from pathlib import Path

import typer

from huske import __version__

app = typer.Typer(
    name="huske",
    help="Always-on terminal audio recorder + local transcription (Whisper).",
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
    from huske.update_check import notify_if_outdated

    notify_if_outdated()
    if ctx.invoked_subcommand is None:
        # Default subcommand is `run`.
        ctx.invoke(run)


@app.command()
def run(
    chunk_minutes: float = typer.Option(15.0, "--chunk-minutes", "-c", min=0.1, max=60.0),
    output_root: Path | None = typer.Option(None, "--output-root"),
    audio_root: Path | None = typer.Option(None, "--audio-root"),
    model: str | None = typer.Option(None, "--model"),
    compute_type: str | None = typer.Option(None, "--compute-type"),
    device: str | None = typer.Option(None, "--device"),
    language: str | None = typer.Option(None, "--language"),
    input_device: str | None = typer.Option(None, "--input-device"),
    keep_audio: bool = typer.Option(False, "--keep-audio/--no-keep-audio"),
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
        help="Seconds between screenshots (default 10, minimum 1).",
    ),
    screenshots_root: Path | None = typer.Option(
        None, "--screenshots-root", help="Where screenshots are written."
    ),
    config_path: Path | None = typer.Option(None, "--config"),
    log_level: str = typer.Option("INFO", "--log-level"),
    no_ui: bool = typer.Option(False, "--no-ui"),
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
) -> None:
    """Start a recording session with live keyboard controls."""
    from huske.run_loop import run_session

    cli_overrides = _collect_overrides(
        chunk_minutes=chunk_minutes,
        output_root=output_root,
        audio_root=audio_root,
        model=model,
        compute_type=compute_type,
        device=device,
        language=language,
        input_device=input_device,
        keep_audio=keep_audio,
        screenshots_enabled=screenshots,
        screenshots_interval_seconds=screenshot_interval,
        screenshots_root=screenshots_root,
        log_level=log_level,
        no_ui=no_ui,
        menu_bar_enabled=menu_bar,
        system_audio_backend=system_audio_backend,
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
        stop_agent()
    except RuntimeError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(1) from exc
    typer.secho(f"✓ Sent SIGTERM to {LAUNCHD_LABEL}.", fg=typer.colors.GREEN)


def _collect_overrides(**kwargs: object) -> dict[str, object]:
    return {k: v for k, v in kwargs.items() if v is not None}
