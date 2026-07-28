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
        help="Suppress system audio that bleeds into the mic over speakers "
        "(coherence-based echo suppression) before transcription. On by "
        "default; self-gating (no effect with headphones).",
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
    keep_audio: bool = typer.Option(False, "--keep-audio/--no-keep-audio"),
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
        help="Distill each finished transcript into searchable statements with "
        "huske's built-in local LLM (downloads on first use). Off by default.",
    ),
    distill_model: str | None = typer.Option(
        None,
        "--distill-model",
        help="Distillation model: a Hugging Face repo for the built-in MLX "
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
# Local semantic search + MCP server (huske[mcp] extra)
# ---------------------------------------------------------------------------


@app.command()
def index(
    output_root: Path | None = typer.Option(None, "--output-root"),
    rebuild: bool = typer.Option(
        False, "--rebuild", help="Drop and rebuild the entire index (e.g. after a model change)."
    ),
    force: bool = typer.Option(
        False, "--force", help="Re-embed even transcripts whose content is unchanged."
    ),
    low_impact: bool | None = typer.Option(
        None,
        "--low-impact/--fast",
        help=(
            "Throttle the backfill (lower CPU priority, smaller batches, capped "
            "MLX memory) so it can't hog the machine. On by default; use --fast "
            "to run at full speed."
        ),
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Build or refresh the local semantic search index from transcripts."""
    from huske.search.runner import run_index

    cli_overrides = _collect_overrides(output_root=output_root)
    raise typer.Exit(
        run_index(
            config_path=config_path,
            cli_overrides=cli_overrides,
            rebuild=rebuild,
            force=force,
            low_impact=low_impact,
        )
    )


@app.command()
def distill(
    output_root: Path | None = typer.Option(None, "--output-root"),
    model: str | None = typer.Option(
        None, "--model", help="Distill with this LLM tag (e.g. qwen3.5:0.8b), overriding config."
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
    """Distill transcripts into searchable statement sidecars with a local LLM.

    Writes a ``<name>.statements.json`` next to each transcript. Run ``huske
    index`` afterwards to embed the statements for two-stage search. Uses the
    built-in MLX model by default (downloads on first use); set
    ``distill_backend = "ollama"`` to delegate to an Ollama daemon instead.
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


mcp_app = typer.Typer(
    name="mcp",
    help="Serve transcript search over MCP, and manage connector access.",
    no_args_is_help=False,
    add_completion=False,
    invoke_without_command=True,
)
app.add_typer(mcp_app)


@mcp_app.callback(invoke_without_command=True)
def mcp(
    ctx: typer.Context,
    host: str | None = typer.Option(
        None, "--host", help="Bind address (default 127.0.0.1, loopback-only)."
    ),
    port: int | None = typer.Option(None, "--port", min=1, max=65535, help="Port (default 7641)."),
    public_url: str | None = typer.Option(
        None,
        "--public-url",
        help="Public HTTPS URL of this endpoint (e.g. https://huske.example.com/mcp). "
        "Turns on connector mode so Claude and ChatGPT can attach it from any "
        "device. Requires `huske mcp set-password`.",
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Serve huske's transcript search over an MCP (HTTP) endpoint."""
    if ctx.invoked_subcommand is not None:
        return

    from huske.config import load_config
    from huske.mcp.server import run as run_mcp

    overrides = _collect_overrides(mcp_public_url=public_url)
    try:
        cfg = load_config(config_path=config_path, cli_overrides=overrides)
    except ValueError as exc:
        typer.secho(f"config: {exc}", fg=typer.colors.RED, err=True)
        raise typer.Exit(2) from exc
    raise typer.Exit(run_mcp(cfg, host=host, port=port))


@mcp_app.command("set-password")
def mcp_set_password() -> None:
    """Set the passphrase that authorizes connector clients (Claude, ChatGPT).

    Stored as a scrypt hash at ``~/.config/huske/mcp_password`` (mode 0600) —
    the plaintext is never written anywhere. This is the only credential between
    the internet and your transcript history when connector mode is on, so pick
    accordingly; a passphrase you would use for a password manager, not one you
    would use for a wifi network.
    """
    from huske.mcp.oauth import save_password_hash

    password = typer.prompt("New connector passphrase", hide_input=True)
    if len(password.strip()) < 12:
        typer.secho(
            "Too short — use at least 12 characters. This guards every transcript "
            "huske has ever written.",
            fg=typer.colors.RED,
            err=True,
        )
        raise typer.Exit(2)
    if password != typer.prompt("Confirm passphrase", hide_input=True):
        typer.secho("Passphrases do not match.", fg=typer.colors.RED, err=True)
        raise typer.Exit(2)

    path = save_password_hash(password)
    typer.secho(f"✓ Wrote {path} (mode 0600)", fg=typer.colors.GREEN)
    typer.echo("")
    typer.echo("Existing connector tokens keep working — run `huske mcp revoke` to")
    typer.echo("cut them off and force every client to sign in again.")


@mcp_app.command("revoke")
def mcp_revoke(
    all_clients: bool = typer.Option(
        False, "--all", help="Revoke every issued connector token (all devices)."
    ),
    client_id: str | None = typer.Option(
        None, "--client-id", help="Revoke only this client's tokens."
    ),
) -> None:
    """Revoke connector access. Loopback clients using the static token are unaffected."""
    if not all_clients and client_id is None:
        typer.secho("Pass --all or --client-id <id>.", fg=typer.colors.RED, err=True)
        raise typer.Exit(2)

    from huske.mcp.oauth import OAuthStore, default_store_path

    path = default_store_path()
    if not path.exists():
        typer.echo("No connector tokens have ever been issued.")
        raise typer.Exit(0)

    store = OAuthStore.open(path)
    try:
        count = (
            store.revoke_all_tokens() if all_clients else store.revoke_client_tokens(client_id or "")
        )
    finally:
        store.close()
    typer.secho(f"✓ Revoked {count} token(s).", fg=typer.colors.GREEN)


@mcp_app.command("status")
def mcp_status(config_path: Path | None = typer.Option(None, "--config")) -> None:
    """Show whether connector mode is configured and how many clients are attached."""
    from huske.config import load_config
    from huske.mcp.oauth import OAuthStore, default_store_path, load_password_hash

    try:
        cfg = load_config(config_path=config_path)
    except ValueError as exc:
        typer.secho(f"config: {exc}", fg=typer.colors.RED, err=True)
        raise typer.Exit(2) from exc

    typer.echo("huske mcp")
    typer.echo(f"  loopback   http://{cfg.mcp_host}:{cfg.mcp_port}/mcp")
    if not cfg.mcp_public_url:
        typer.echo("  connector  off (mcp_public_url is unset)")
        typer.echo("")
        typer.echo("Run `huske connect` to see what each client needs.")
        raise typer.Exit(0)

    has_password = load_password_hash() is not None
    typer.echo(f"  connector  {cfg.mcp_public_url}")
    typer.echo(f"  passphrase {'set' if has_password else 'NOT SET — `huske mcp set-password`'}")
    path = default_store_path()
    if path.exists():
        store = OAuthStore.open(path)
        try:
            typer.echo(f"  clients    {store.count_clients()} registered")
            typer.echo(f"  tokens     {store.live_token_count()} live access token(s)")
        finally:
            store.close()
    else:
        typer.echo("  clients    none yet")
    raise typer.Exit(0 if has_password else 1)


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

    The MCP connector (`huske connect`) stays the better path: it keeps semantic
    search, statement grounding, and custody of the data. Syncing this folder to
    a third-party cloud puts plaintext transcripts there — see
    docs/integrations.md.
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
def connect(
    client: str | None = typer.Argument(
        None,
        help="Which client to wire up: claude-code, claude-desktop, claude-app, "
        "chatgpt, codex, cursor, hermes. Omit for a summary of all of them.",
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Show exactly how to connect huske to each LLM client, and what works today."""
    from huske.connect import run_connect

    raise typer.Exit(run_connect(client, config_path=config_path))


# ---------------------------------------------------------------------------
# Off-device huske server: replication client + serve side (huske[server])
# ---------------------------------------------------------------------------


@app.command()
def serve(
    ingest_host: str | None = typer.Option(
        None, "--ingest-host", help="Bind address (default 127.0.0.1, behind a TLS reverse proxy)."
    ),
    ingest_port: int | None = typer.Option(
        None, "--ingest-port", min=1, max=65535, help="Port (default 7642)."
    ),
    public_host: str | None = typer.Option(
        None, "--public-host", help="Public hostname the reverse proxy serves (validates Host)."
    ),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Run the off-device huske server: receive pushed transcripts and index them.

    Single-tenant. Pair with `huske mcp` (the loopback read side) on the same
    host for your co-located agent. See docs/server.md and
    docs/adr/0004-off-device-huske-server.md.
    """
    from huske.config import load_config
    from huske.server.serve import run as run_serve

    overrides = _collect_overrides(
        ingest_host=ingest_host, ingest_port=ingest_port, public_host=public_host
    )
    try:
        cfg = load_config(config_path=config_path, cli_overrides=overrides)
    except ValueError as exc:
        typer.secho(f"config: {exc}", fg=typer.colors.RED, err=True)
        raise typer.Exit(2) from exc
    raise typer.Exit(run_serve(cfg))


@app.command()
def sync(
    output_root: Path | None = typer.Option(None, "--output-root"),
    config_path: Path | None = typer.Option(None, "--config"),
) -> None:
    """Push every not-yet-replicated transcript to your huske server, then exit."""
    from huske.sync.runner import run_sync

    overrides = _collect_overrides(output_root=output_root)
    raise typer.Exit(run_sync(config_path=config_path, cli_overrides=overrides))


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
