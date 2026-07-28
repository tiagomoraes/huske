"""``huske setup``: one guided command that gets an LLM reading your transcripts.

Connecting huske used to be five commands and a hand-edited JSON file: install
the extra, build the index, start the daemon, find the token, then paste it into
a client config in a directory most people have never opened. Every one of those
steps is a place to stop, and none of them tells you which step you are on.

So this command owns the whole local path and answers three questions at once —
*what state am I in, what is left, and can you just do it for me* — for the one
audience that cannot fall back to reading the docs.

Two deliberate limits:

- **It never installs software.** Detecting a missing extra and printing the
  exact upgrade line is honest; silently running a package manager against
  someone's Python is not. Same rule ``distill_auto_manage`` follows for Ollama.
- **The cross-device path is not made to look local.** It needs a server, TLS,
  and a reverse proxy. `--connector` prepares the huske side and then says so,
  rather than pretending a wizard can conjure a host.

The state model is shared with the macOS app through ``--json`` so the app stays
a shell over this logic rather than a second implementation of it (ADR 0006).
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Literal

if TYPE_CHECKING:
    from huske.config import RuntimeConfig

State = Literal["ok", "todo", "blocked", "optional"]

CLAUDE_DESKTOP_CONFIG = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Claude"
    / "claude_desktop_config.json"
)


@dataclass(slots=True)
class Step:
    """One thing that is either done, doable, or blocked on the user."""

    key: str
    title: str
    state: State
    detail: str
    fix: str | None = None
    # True when `huske setup --apply <key>` can complete it without a terminal.
    can_apply: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "title": self.title,
            "state": self.state,
            "detail": self.detail,
            "fix": self.fix,
            "can_apply": self.can_apply,
        }


@dataclass(slots=True)
class Report:
    steps: list[Step] = field(default_factory=list)
    endpoint: str = ""
    connector_url: str | None = None

    # An LLM can only search when all three hold: the extra is importable, the
    # index has the transcripts, and something is listening. Reporting "ready"
    # with the server down would send someone to their agent to watch it fail.
    REQUIRED = ("extra", "index", "server")

    @property
    def ready(self) -> bool:
        """True when an LLM on this Mac can actually search right now."""
        by_key = {s.key: s for s in self.steps}
        return all(by_key[k].state == "ok" for k in self.REQUIRED if k in by_key)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ready": self.ready,
            "endpoint": self.endpoint,
            "connector_url": self.connector_url,
            "steps": [s.to_dict() for s in self.steps],
        }


# --- detection ---------------------------------------------------------------


def extra_installed() -> bool:
    """Is the ``huske[mcp]`` extra importable?"""
    try:
        import mcp  # noqa: F401
        import sqlite_vec  # noqa: F401
    except ImportError:
        return False
    return True


def installed_via() -> str:
    """How this huske was installed: ``uv``, ``brew``, ``pipx``, or ``pip``.

    Read from the running interpreter's own path rather than guessed, because
    the wrong upgrade command is the worst possible answer here: it appears to
    succeed and changes nothing, and the user has no way to tell.
    """
    prefix = sys.prefix.lower()
    if "/uv/tools/" in prefix or "/.local/share/uv" in prefix:
        return "uv"
    if "/cellar/" in prefix or "/homebrew/" in prefix:
        return "brew"
    if "/pipx/" in prefix:
        return "pipx"
    return "pip"


def upgrade_command() -> str:
    """The command that actually adds the search extra to *this* install."""
    manager = installed_via()
    if manager == "uv":
        return 'uv tool install --force "huske[mcp]"'
    if manager == "brew":
        # NOT `brew reinstall`: the tap formula pins its dependencies as wheel
        # resources and does not carry the search ones (no sqlite-vec, mcp,
        # mlx-embeddings, or uvicorn), so a reinstall rebuilds the same venv
        # without them. Installing into the formula's own interpreter is the
        # one route that keeps a single engine — with the caveat below.
        return f'"{sys.prefix}/bin/python" -m pip install "huske[mcp]"'
    if manager == "pipx":
        return 'pipx install --force "huske[mcp]"'
    return "pip install --upgrade 'huske[mcp]'"


def upgrade_caveat() -> str | None:
    """A truthful warning about the upgrade route, when one is needed."""
    if installed_via() == "brew":
        return (
            "Homebrew's formula does not ship the search dependencies, so this "
            "adds them to its virtualenv — a later `brew upgrade huske` rebuilds "
            "that venv and drops them. Installing with `uv tool install "
            '"huske[mcp]"` instead avoids the reset.'
        )
    return None


def index_status(cfg: RuntimeConfig) -> tuple[bool, int]:
    """``(exists, passage_count)`` for the local index, without needing the extra."""
    from huske.paths import index_db_path

    db = index_db_path(cfg)
    if not db.exists():
        return False, 0
    try:
        import sqlite3

        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            row = conn.execute("SELECT value FROM index_meta WHERE key='dim'").fetchone()
            if row is None:
                return False, 0
            # `passages` is a vec0 virtual table, which needs the extension to
            # query — but `indexed_files` is plain SQL, so transcript count is
            # readable without it. That keeps this check dependency-free.
            count = conn.execute("SELECT count(*) FROM indexed_files").fetchone()[0]
            return True, int(count)
        finally:
            conn.close()
    except Exception:
        return False, 0


def transcript_count(cfg: RuntimeConfig) -> int:
    from huske.search.indexer import iter_transcripts

    return len(iter_transcripts(cfg.output_root))


def server_running(cfg: RuntimeConfig, *, timeout: float = 0.35) -> bool:
    """Is something listening on the MCP endpoint?"""
    try:
        with socket.create_connection((cfg.mcp_host, cfg.mcp_port), timeout=timeout):
            return True
    except OSError:
        return False


def has_executable(name: str) -> bool:
    return shutil.which(name) is not None


# --- client wiring -----------------------------------------------------------


@dataclass(slots=True)
class ClientTarget:
    key: str
    label: str
    detected: bool
    can_apply: bool
    detail: str


def detect_clients() -> list[ClientTarget]:
    """Which LLM clients are present on this Mac, and which we can wire up."""
    desktop_present = CLAUDE_DESKTOP_CONFIG.parent.exists()
    return [
        ClientTarget(
            key="claude-desktop",
            label="Claude Desktop",
            detected=desktop_present,
            # Needs npx for the mcp-remote bridge; without node we can write the
            # config but it would not run, so say so instead of half-doing it.
            can_apply=desktop_present and has_executable("npx"),
            detail=(
                "installed" if desktop_present else "not found"
            )
            + ("" if has_executable("npx") else " · needs Node.js (npx) for the bridge"),
        ),
        ClientTarget(
            key="claude-code",
            label="Claude Code",
            detected=has_executable("claude"),
            can_apply=has_executable("claude"),
            detail="installed" if has_executable("claude") else "not found",
        ),
    ]


def claude_desktop_entry(cfg: RuntimeConfig, token: str) -> dict[str, Any]:
    """The ``mcpServers.huske`` block for Claude Desktop.

    Desktop's connector UI cannot attach a bearer header to a loopback URL, so
    the supported route is an ``mcp-remote`` stdio bridge. ``Authorization:`` is
    written with no space on purpose — Desktop strips spaces inside args.
    """
    return {
        "command": "npx",
        "args": [
            "-y",
            "mcp-remote",
            f"http://{cfg.mcp_host}:{cfg.mcp_port}/mcp",
            "--allow-http",
            "--header",
            "Authorization:${HUSKE_MCP_TOKEN}",
        ],
        "env": {"HUSKE_MCP_TOKEN": f"Bearer {token}"},
    }


def apply_claude_desktop(cfg: RuntimeConfig, token: str) -> tuple[bool, str]:
    """Merge huske into Claude Desktop's config. Returns ``(changed, message)``.

    Merges rather than writes: this file may hold other MCP servers the user
    depends on, and clobbering it to add ours would be an unacceptable trade for
    saving a JSON edit. The original is backed up once, the write is atomic, and
    unparseable JSON is refused rather than replaced.
    """
    path = CLAUDE_DESKTOP_CONFIG
    if not path.parent.exists():
        return False, "Claude Desktop is not installed (no config directory)."

    existing: dict[str, Any] = {}
    if path.exists():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8") or "{}")
        except ValueError:
            return False, (
                f"{path} is not valid JSON. Fix or remove it, then run this again — "
                "huske will not overwrite a file it cannot parse."
            )
        if not isinstance(loaded, dict):
            return False, f"{path} is not a JSON object; leaving it alone."
        existing = loaded
        backup = path.with_suffix(path.suffix + ".huske-backup")
        if not backup.exists():
            # Only the first backup: it preserves the state before huske ever
            # touched the file, which is the one a user would want to restore.
            shutil.copy2(path, backup)

    servers = existing.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
    wanted = claude_desktop_entry(cfg, token)
    if servers.get("huske") == wanted:
        return False, "Claude Desktop is already connected."

    servers["huske"] = wanted
    existing["mcpServers"] = servers
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return True, (
        "Connected Claude Desktop. Quit and reopen it (⌘Q, not just the window) "
        "for the change to load."
    )


def claude_code_command(cfg: RuntimeConfig) -> list[str]:
    return [
        "claude",
        "mcp",
        "add",
        "--transport",
        "http",
        "huske",
        f"http://{cfg.mcp_host}:{cfg.mcp_port}/mcp",
        "--header",
        f"Authorization: Bearer {_token_or_placeholder()}",
    ]


def apply_claude_code(cfg: RuntimeConfig) -> tuple[bool, str]:
    """Register huske with Claude Code by running its own CLI."""
    import subprocess

    if not has_executable("claude"):
        return False, "Claude Code is not installed (no `claude` on PATH)."
    try:
        # Fixed argv, no shell — the only variable is our own endpoint.
        result = subprocess.run(
            claude_code_command(cfg),
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"Could not run `claude mcp add`: {exc}"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        return False, f"`claude mcp add` failed: {detail[0] if detail else 'unknown error'}"
    return True, "Connected Claude Code."


def _token_or_placeholder() -> str:
    from huske.mcp.token import default_token_path, load_token

    return load_token(default_token_path()) or "<run `huske mcp` once to mint a token>"


# --- the report --------------------------------------------------------------


def build_report(cfg: RuntimeConfig) -> Report:
    """Assess every step of the local path without changing anything."""
    report = Report(endpoint=f"http://{cfg.mcp_host}:{cfg.mcp_port}/mcp")
    report.connector_url = cfg.mcp_public_url

    if extra_installed():
        report.steps.append(
            Step("extra", "Search engine installed", "ok", "huske[mcp] is present")
        )
    else:
        detail = "The huske[mcp] extra adds on-device embeddings and the MCP server."
        caveat = upgrade_caveat()
        if caveat:
            detail = f"{detail} {caveat}"
        report.steps.append(
            Step("extra", "Search engine installed", "blocked", detail, fix=upgrade_command())
        )

    transcripts = transcript_count(cfg)
    indexed_ok, indexed_files = index_status(cfg)
    if transcripts == 0:
        report.steps.append(
            Step(
                "index",
                "Transcripts indexed",
                "todo",
                "Nothing recorded yet — record something first, then index it.",
                fix="huske index",
            )
        )
    elif indexed_ok and indexed_files >= transcripts:
        report.steps.append(
            Step(
                "index",
                "Transcripts indexed",
                "ok",
                f"{indexed_files} of {transcripts} transcript(s) indexed",
            )
        )
    else:
        report.steps.append(
            Step(
                "index",
                "Transcripts indexed",
                "todo",
                f"{indexed_files} of {transcripts} transcript(s) indexed",
                fix="huske index",
                can_apply=extra_installed(),
            )
        )

    running = server_running(cfg)
    report.steps.append(
        Step(
            "server",
            "Search server running",
            "ok" if running else "todo",
            f"listening on {cfg.mcp_host}:{cfg.mcp_port}"
            if running
            else "Start it so clients can reach the index.",
            fix=None if running else "huske mcp",
        )
    )

    for client in detect_clients():
        report.steps.append(
            Step(
                client.key,
                client.label,
                "ok" if client.detected else "optional",
                client.detail,
                can_apply=client.can_apply,
            )
        )

    if cfg.mcp_public_url:
        from huske.mcp.oauth import load_password_hash

        has_password = load_password_hash() is not None
        report.steps.append(
            Step(
                "connector",
                "Reachable from other devices",
                "ok" if has_password else "todo",
                cfg.mcp_public_url
                if has_password
                else "No passphrase set yet.",
                fix=None if has_password else "huske mcp set-password",
            )
        )
    else:
        report.steps.append(
            Step(
                "connector",
                "Reachable from other devices",
                "optional",
                "Off. Needs a server you control (TLS + reverse proxy) — see "
                "docs/integrations.md.",
            )
        )
    return report


# --- rendering ---------------------------------------------------------------

_GLYPH = {"ok": "✓", "todo": "•", "blocked": "✗", "optional": "·"}


def render(report: Report) -> str:
    lines = ["", "huske setup", ""]
    for step in report.steps:
        lines.append(f"  {_GLYPH[step.state]} {step.title}")
        if step.detail:
            lines.append(f"      {step.detail}")
        if step.fix:
            lines.append(f"      → {step.fix}")
    lines.append("")

    blocked = [s for s in report.steps if s.state == "blocked"]
    todo = [s for s in report.steps if s.state == "todo"]
    if blocked:
        lines += [
            "Start here:",
            f"  {blocked[0].fix}",
            "",
            "Then run `huske setup` again.",
        ]
    elif todo:
        appliable = [s for s in todo if s.can_apply]
        lines.append("Next:")
        for step in todo:
            lines.append(f"  {step.fix}" if step.fix else f"  {step.title}")
        if any(s.key == "server" for s in todo):
            lines.append("      (`huske mcp` keeps running — leave it open, or let")
            lines.append("       Huske.app start it for you)")
        if appliable:
            lines += ["", "Or let huske do it:", "  huske setup --apply all"]
    elif report.ready:
        lines += [
            "Ready. Ask your agent something only a meeting would know —",
            '  "what did we decide about pricing?"',
            "",
            "Not connected yet? `huske setup --apply claude-desktop` (or",
            "`--apply claude-code`) wires it up without editing any files by hand.",
        ]
    if not report.connector_url:
        lines += [
            "",
            "Want this from your phone? That needs an always-on server —",
            "`huske connect claude-app` explains what it takes.",
        ]
    lines.append("")
    return "\n".join(lines)


# --- entry point -------------------------------------------------------------


def run_setup(
    config_path: Path | None = None,
    *,
    json_output: bool = False,
    apply: str | None = None,
) -> int:
    """Assess (and optionally complete) the local setup. Returns an exit code."""
    from huske.config import load_config

    try:
        cfg = load_config(config_path=config_path)
    except ValueError as exc:
        print(f"config: {exc}")
        return 2

    if apply:
        return _run_apply(cfg, apply)

    report = build_report(cfg)
    if json_output:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        print(render(report))
    return 0 if report.ready else 1


def _run_apply(cfg: RuntimeConfig, apply: str) -> int:
    targets = ["index", "claude-desktop", "claude-code"] if apply == "all" else [apply]
    known = {"claude-desktop", "claude-code", "index"}
    unknown = [t for t in targets if t not in known]
    if unknown:
        print(f"unknown target(s): {', '.join(unknown)}\nknown: {', '.join(sorted(known))}")
        return 2

    from huske.mcp.token import default_token_path, load_or_create_token

    failures = 0
    for target in targets:
        if target == "index":
            from huske.search.runner import run_index

            code = run_index(rebuild=False, force=False, low_impact=None)
            failures += 1 if code else 0
            continue
        if target == "claude-desktop":
            token = load_or_create_token(default_token_path())
            changed, message = apply_claude_desktop(cfg, token)
        else:
            changed, message = apply_claude_code(cfg)
        print(("✓ " if changed else "  ") + message)
        if not changed and "already" not in message.lower():
            failures += 1
    return 1 if failures else 0
