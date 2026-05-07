"""Best-effort PyPI version check with a stderr banner when huske is outdated.

Design goals:

- Zero added dependencies (stdlib ``urllib`` only).
- Non-blocking startup: prints from a 24 h disk cache; refreshes in a daemon
  thread.
- Tells the user the *exact* upgrade command for their install method
  (``uv tool``, ``pipx``, ``brew``) by inspecting ``sys.executable``.
- Silent on network failures, non-TTY stderr, editable installs, and when the
  user sets ``HUSKE_NO_UPDATE_CHECK=1``.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from huske import __version__

__all__ = ["notify_if_outdated"]


_PYPI_URL = "https://pypi.org/pypi/huske/json"
_CACHE_TTL = timedelta(hours=24)
_FETCH_TIMEOUT_SECONDS = 2.0

_UPGRADE_COMMANDS: dict[str, str] = {
    "uv": "uv tool upgrade huske",
    "pipx": "pipx upgrade huske",
    "brew": "brew upgrade huske",
}


def notify_if_outdated() -> None:
    """Show an "update available" banner on stderr if PyPI has a newer version.

    Cheap and non-blocking: reads a cached check result from disk, prints a
    banner if outdated, and kicks off a background refresh when the cache is
    older than 24 h. Never raises.
    """
    try:
        if _is_disabled() or _is_editable_install() or not _stderr_is_tty():
            return

        cached = _load_cache()
        latest = (cached or {}).get("latest_version")
        if isinstance(latest, str) and _is_newer(latest, __version__):
            _print_banner(__version__, latest)

        if _cache_is_stale(cached):
            _spawn_refresh()
    except Exception:
        # Never let a version check break the CLI.
        return


# ---------------------------------------------------------------------------
# Opt-out / environment
# ---------------------------------------------------------------------------


def _is_disabled() -> bool:
    raw = os.environ.get("HUSKE_NO_UPDATE_CHECK", "").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def _stderr_is_tty() -> bool:
    try:
        return bool(sys.stderr.isatty())
    except (AttributeError, ValueError):
        return False


def _is_editable_install() -> bool:
    """Heuristic: an editable install lives outside ``site-packages``.

    `uv tool`, `pipx`, and `brew` all install into venvs whose ``huske``
    package sits under ``…/site-packages/huske``. A ``pip install -e .``
    leaves ``huske/__init__.py`` in the source tree, which is exactly what we
    want to silence the banner for during development.
    """
    try:
        parts = Path(__file__).resolve().parts
    except OSError:
        return False
    return "site-packages" not in parts


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------


def _cache_path() -> Path:
    base = os.environ.get("HUSKE_UPDATE_CHECK_CACHE")
    if base:
        return Path(base)
    xdg = os.environ.get("XDG_CACHE_HOME")
    root = Path(xdg) if xdg else Path.home() / ".cache"
    return root / "huske" / "update-check.json"


def _load_cache() -> dict[str, Any] | None:
    path = _cache_path()
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _save_cache(latest_version: str) -> None:
    path = _cache_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "checked_at": datetime.now(timezone.utc).isoformat(),
            "latest_version": latest_version,
        }
        tmp = path.with_suffix(path.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except OSError:
        return


def _cache_is_stale(cached: dict[str, Any] | None) -> bool:
    if not cached:
        return True
    when_raw = cached.get("checked_at")
    if not isinstance(when_raw, str):
        return True
    try:
        when = datetime.fromisoformat(when_raw)
    except ValueError:
        return True
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - when > _CACHE_TTL


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------


def _spawn_refresh() -> None:
    threading.Thread(target=_refresh, name="huske-update-check", daemon=True).start()


def _refresh() -> None:
    latest = _fetch_latest_version()
    if latest:
        _save_cache(latest)


def _fetch_latest_version() -> str | None:
    url = os.environ.get("HUSKE_UPDATE_CHECK_URL", _PYPI_URL)
    try:
        request = urllib.request.Request(
            url,
            headers={"User-Agent": f"huske/{__version__} (+https://github.com/tiagomoraes/huske)"},
        )
        with urllib.request.urlopen(request, timeout=_FETCH_TIMEOUT_SECONDS) as resp:
            payload = json.load(resp)
    except Exception:
        return None
    info = payload.get("info") if isinstance(payload, dict) else None
    if isinstance(info, dict):
        version = info.get("version")
        if isinstance(version, str) and version.strip():
            return version.strip()
    return None


# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------


_VERSION_RE = re.compile(r"^\s*v?(\d+(?:\.\d+)*)")


def _parse_version(v: str) -> tuple[int, ...]:
    """Return the leading numeric segments of ``v`` as a tuple.

    Tolerates pre-release/dev suffixes (``0.2.0rc1`` → ``(0, 2, 0)``) and a
    leading ``v``. Returns ``(0,)`` for unparseable input so that callers can
    safely compare without raising.
    """
    if not isinstance(v, str):
        return (0,)
    m = _VERSION_RE.match(v)
    if not m:
        return (0,)
    return tuple(int(p) for p in m.group(1).split("."))


def _is_newer(latest: str, current: str) -> bool:
    return _parse_version(latest) > _parse_version(current)


# ---------------------------------------------------------------------------
# Install-method detection
# ---------------------------------------------------------------------------


def _detect_install_method() -> str:
    """Best-effort: ``uv``, ``pipx``, ``brew``, or ``unknown``.

    Inspects ``sys.executable`` *unresolved*. A venv created by ``uv tool``
    or ``pipx`` has ``bin/python`` symlinked to a base interpreter — which on
    macOS is often Homebrew Python. Resolving that symlink would point us
    into ``/opt/homebrew/Cellar/python@…/…`` and misclassify a pipx/uv
    install as brew. The unresolved path keeps the enclosing tool's directory
    intact, which is exactly the signal we want.

    Order matters: check uv/pipx markers before brew, so that a pipx venv
    using Homebrew Python is still detected as pipx.
    """
    try:
        exe_raw = sys.executable or ""
    except Exception:
        return "unknown"
    exe = exe_raw.replace("\\", "/").lower()

    if "/uv/tools/" in exe:
        return "uv"
    if "/pipx/" in exe and "/venvs/" in exe:
        return "pipx"
    if "/cellar/" in exe or "/homebrew/" in exe or "/linuxbrew/" in exe:
        return "brew"
    return "unknown"


# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------


def _print_banner(current: str, latest: str) -> None:
    method = _detect_install_method()
    cmd = _UPGRADE_COMMANDS.get(method)

    try:
        from rich.console import Console

        console = Console(stderr=True, highlight=False, soft_wrap=True)
        console.print(
            f"[yellow]huske[/yellow] [bold]{latest}[/bold] is available "
            f"[dim](you have {current}).[/dim]"
        )
        if cmd:
            console.print(f"[dim]To upgrade, run:[/dim] [cyan]{cmd}[/cyan]")
        else:
            options = ", ".join(_UPGRADE_COMMANDS.values())
            console.print(f"[dim]To upgrade, run one of:[/dim] [cyan]{options}[/cyan]")
        console.print(
            "[dim]Silence this with HUSKE_NO_UPDATE_CHECK=1.[/dim]"
        )
    except Exception:
        # Plain fallback if Rich misbehaves on an exotic terminal.
        line1 = f"huske {latest} is available (you have {current})."
        line2 = (
            f"To upgrade, run: {cmd}"
            if cmd
            else "To upgrade, run one of: " + ", ".join(_UPGRADE_COMMANDS.values())
        )
        line3 = "Silence this with HUSKE_NO_UPDATE_CHECK=1."
        print(line1, file=sys.stderr, flush=True)
        print(line2, file=sys.stderr, flush=True)
        print(line3, file=sys.stderr, flush=True)
