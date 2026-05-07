"""Typer CLI shell — subcommands wire up below as they land."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

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
    if ctx.invoked_subcommand is None:
        # Default subcommand is `run`.
        ctx.invoke(run)


@app.command()
def run(
    chunk_minutes: float = typer.Option(15.0, "--chunk-minutes", "-c", min=0.1, max=60.0),
    output_root: Optional[Path] = typer.Option(None, "--output-root"),
    audio_root: Optional[Path] = typer.Option(None, "--audio-root"),
    model: Optional[str] = typer.Option(None, "--model"),
    compute_type: Optional[str] = typer.Option(None, "--compute-type"),
    device: Optional[str] = typer.Option(None, "--device"),
    language: Optional[str] = typer.Option(None, "--language"),
    input_device: Optional[str] = typer.Option(None, "--input-device"),
    keep_audio: bool = typer.Option(False, "--keep-audio/--no-keep-audio"),
    config_path: Optional[Path] = typer.Option(None, "--config"),
    log_level: str = typer.Option("INFO", "--log-level"),
    no_ui: bool = typer.Option(False, "--no-ui"),
) -> None:
    """Start a recording session. Press Ctrl+C or 'q' to stop."""
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
        log_level=log_level,
        no_ui=no_ui,
    )
    raise typer.Exit(run_session(config_path=config_path, cli_overrides=cli_overrides))


@app.command()
def recover(
    output_root: Optional[Path] = typer.Option(None, "--output-root"),
    audio_root: Optional[Path] = typer.Option(None, "--audio-root"),
    model: Optional[str] = typer.Option(None, "--model"),
    compute_type: Optional[str] = typer.Option(None, "--compute-type"),
    device: Optional[str] = typer.Option(None, "--device"),
    language: Optional[str] = typer.Option(None, "--language"),
    config_path: Optional[Path] = typer.Option(None, "--config"),
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
    input_device: Optional[str] = typer.Option(None, "--input-device"),
    config_path: Optional[Path] = typer.Option(None, "--config"),
    json_output: bool = typer.Option(False, "--json"),
) -> None:
    """Validate audio devices, model availability, and write paths."""
    from huske.doctor import run_doctor

    cli_overrides = _collect_overrides(input_device=input_device)
    raise typer.Exit(run_doctor(config_path=config_path, cli_overrides=cli_overrides, json_output=json_output))


def _collect_overrides(**kwargs: object) -> dict[str, object]:
    return {k: v for k, v in kwargs.items() if v is not None}
