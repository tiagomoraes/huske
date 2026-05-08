"""Tests for package version metadata."""

from __future__ import annotations

import tomllib
from pathlib import Path

from huske import __version__


def test_runtime_version_matches_project_version() -> None:
    pyproject_path = Path(__file__).resolve().parents[2] / "pyproject.toml"
    pyproject = tomllib.loads(pyproject_path.read_text(encoding="utf-8"))

    assert __version__ == pyproject["project"]["version"]
