"""macOS LaunchAgent management for autostart on login.

Generates a per-user LaunchAgent plist that runs a headless ``huske run`` and
manages its lifecycle via ``launchctl``. macOS only — every public function
raises :class:`UnsupportedPlatformError` on other systems.

Prefer the Huske.app "Open at login" + "Start recording when Huske opens"
toggles for the everyday autostart; this LaunchAgent remains for setups that
want the engine with no app at all (the menu bar helper is then the UI).

The plist lives at ``~/Library/LaunchAgents/me.huske.plist`` and stdout/stderr
are appended to ``~/Library/Logs/huske/agent.{out,err}.log``.
"""

from __future__ import annotations

import os
import platform
import plistlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

LAUNCHD_LABEL = "me.huske"
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCHD_LABEL}.plist"
LOG_DIR = Path.home() / "Library" / "Logs" / "huske"
LOG_OUT = LOG_DIR / "agent.out.log"
LOG_ERR = LOG_DIR / "agent.err.log"

# launchd inherits a minimal PATH; explicit Homebrew + standard prefixes keep
# `huske` and ffmpeg discoverable regardless of how the binary was installed.
DEFAULT_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"


class UnsupportedPlatformError(RuntimeError):
    """Raised when autostart commands are invoked off macOS."""


@dataclass(frozen=True)
class AgentStatus:
    """Snapshot of the LaunchAgent's current state."""

    installed: bool
    loaded: bool
    pid: int | None
    last_exit_code: int | None
    plist_path: Path
    log_out: Path
    log_err: Path


def _ensure_macos() -> None:
    if platform.system() != "Darwin":
        raise UnsupportedPlatformError(
            "huske autostart is macOS-only (uses launchd)."
        )


def _user_domain() -> str:
    """Return ``gui/<uid>`` — the modern launchctl domain target for a user."""
    return f"gui/{os.getuid()}"


def _service_target() -> str:
    return f"{_user_domain()}/{LAUNCHD_LABEL}"


def resolve_huske_binary() -> list[str]:
    """Return the argv prefix that invokes ``huske``.

    Prefers an absolute path from ``PATH`` so the agent survives venv
    deactivation; falls back to ``[sys.executable, "-m", "huske"]``.
    """
    found = shutil.which("huske")
    if found:
        return [found]
    return [sys.executable, "-m", "huske"]


def build_program_args(
    *,
    huske_argv: list[str] | None = None,
    config_path: Path | None = None,
    log_level: str = "INFO",
) -> list[str]:
    """Compose ``ProgramArguments`` for the plist."""
    base = list(huske_argv) if huske_argv is not None else resolve_huske_binary()
    args = [*base, "run", "--log-level", log_level]
    if config_path is not None:
        args.extend(["--config", str(config_path.expanduser().resolve())])
    return args


def render_plist(
    *,
    program_args: list[str],
    keep_alive: bool = True,
    log_out: Path = LOG_OUT,
    log_err: Path = LOG_ERR,
    path_env: str = DEFAULT_PATH,
    home: Path | None = None,
) -> str:
    """Serialize the LaunchAgent plist as XML.

    Pure: builds and returns the XML without touching the filesystem or
    invoking launchctl. ``keep_alive=True`` makes launchd restart on crash
    only (``SuccessfulExit=false``); a clean exit stays stopped.
    """
    home = home or Path.home()
    plist: dict[str, object] = {
        "Label": LAUNCHD_LABEL,
        "ProgramArguments": list(program_args),
        "RunAtLoad": True,
        "ProcessType": "Interactive",
        "WorkingDirectory": str(home),
        "StandardOutPath": str(log_out),
        "StandardErrorPath": str(log_err),
        "EnvironmentVariables": {
            "PATH": path_env,
            "HOME": str(home),
        },
    }
    if keep_alive:
        plist["KeepAlive"] = {"SuccessfulExit": False}
    return plistlib.dumps(plist).decode("utf-8")


def _run_launchctl(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["launchctl", *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _launchctl_failure(action: str, result: subprocess.CompletedProcess[str]) -> RuntimeError:
    detail = result.stderr.strip() or result.stdout.strip() or "(no output)"
    return RuntimeError(
        f"launchctl {action} failed (exit {result.returncode}): {detail}"
    )


def install_agent(
    *,
    config_path: Path | None = None,
    log_level: str = "INFO",
    keep_alive: bool = True,
    force: bool = False,
) -> Path:
    """Write the plist and load it with launchd. Returns the plist path.

    Raises :class:`FileExistsError` if the plist already exists and ``force``
    is false. If a previous instance is loaded, it is booted out first so
    ``bootstrap`` can replace it cleanly.
    """
    _ensure_macos()

    if PLIST_PATH.exists() and not force:
        raise FileExistsError(
            f"{PLIST_PATH} already exists. Use --force to overwrite."
        )

    program_args = build_program_args(
        config_path=config_path,
        log_level=log_level,
    )
    xml = render_plist(program_args=program_args, keep_alive=keep_alive)

    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    PLIST_PATH.write_text(xml, encoding="utf-8")

    # Bootout any prior instance so bootstrap won't conflict. Exit code is
    # ignored: nonzero just means nothing was loaded.
    _run_launchctl(["bootout", _service_target()])

    result = _run_launchctl(["bootstrap", _user_domain(), str(PLIST_PATH)])
    if result.returncode != 0:
        raise _launchctl_failure("bootstrap", result)
    return PLIST_PATH


def uninstall_agent() -> bool:
    """Bootout and remove the plist. Returns True if anything was removed."""
    _ensure_macos()
    removed_any = False

    bootout = _run_launchctl(["bootout", _service_target()])
    if bootout.returncode == 0:
        removed_any = True

    if PLIST_PATH.exists():
        PLIST_PATH.unlink()
        removed_any = True

    return removed_any


def agent_status() -> AgentStatus:
    """Return the current state of the LaunchAgent."""
    _ensure_macos()

    installed = PLIST_PATH.exists()
    result = _run_launchctl(["print", _service_target()])
    loaded = result.returncode == 0

    pid: int | None = None
    last_exit: int | None = None
    if loaded:
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("pid = "):
                try:
                    pid = int(stripped.split("=", 1)[1].strip())
                except ValueError:
                    pid = None
            elif stripped.startswith("last exit code = "):
                value = stripped.split("=", 1)[1].strip()
                try:
                    last_exit = int(value)
                except ValueError:
                    last_exit = None

    return AgentStatus(
        installed=installed,
        loaded=loaded,
        pid=pid,
        last_exit_code=last_exit,
        plist_path=PLIST_PATH,
        log_out=LOG_OUT,
        log_err=LOG_ERR,
    )


def start_agent() -> None:
    """Kickstart the agent (start if stopped, no-op if already running)."""
    _ensure_macos()
    result = _run_launchctl(["kickstart", _service_target()])
    if result.returncode != 0:
        raise _launchctl_failure("kickstart", result)


def stop_agent() -> bool:
    """Send ``SIGTERM`` to the running agent; return whether one was sent.

    With ``KeepAlive={SuccessfulExit:false}``, a graceful exit (code 0) keeps
    the agent stopped until the next login. If huske exits non-zero, launchd
    will restart it. Asking launchd to stop an already-idle service is a
    successful no-op.
    """
    _ensure_macos()
    result = _run_launchctl(["kill", "TERM", _service_target()])
    if result.returncode == 0:
        return True

    detail = result.stderr.strip() or result.stdout.strip()
    if result.returncode == 3 and "No process to signal" in detail:
        return False

    raise _launchctl_failure("kill TERM", result)
