"""Huske — always-on terminal audio recorder + local transcription."""

from __future__ import annotations

from importlib.metadata import PackageNotFoundError
from importlib.metadata import version as _pkg_version


def _resolve_version() -> str:
    """Single-source-of-truth version: pyproject.toml when adjacent, else dist-info.

    In a dev checkout (or editable install) the project's ``pyproject.toml`` is
    next to the package, so we read it directly — that way a `version =` bump
    is reflected immediately, without a re-install. For wheels/sdists installed
    from PyPI, ``pyproject.toml`` is not present and we fall back to the
    distribution metadata that pip wrote.
    """
    import tomllib
    from pathlib import Path

    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    if pyproject.exists():
        try:
            with pyproject.open("rb") as f:
                data = tomllib.load(f)
            project = data.get("project") or {}
            if project.get("name") == "huske" and "version" in project:
                return str(project["version"])
        except (OSError, tomllib.TOMLDecodeError):
            pass

    try:
        return _pkg_version("huske")
    except PackageNotFoundError:
        return "0.0.0+source"


__version__ = _resolve_version()
