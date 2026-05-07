"""Smoke tests that exercise the CLI subcommands as subprocesses."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest


pytestmark = pytest.mark.integration


def _run_huske(*args: str, env_extra: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, "-m", "huske", *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
        check=False,
    )


def test_help_exit_zero() -> None:
    result = _run_huske("--help")
    assert result.returncode == 0
    assert "huske" in result.stdout
    assert "run" in result.stdout
    assert "recover" in result.stdout
    assert "doctor" in result.stdout


def test_version_prints_semver() -> None:
    result = _run_huske("--version")
    assert result.returncode == 0
    assert "huske " in result.stdout


def test_doctor_json_runs(tmp_path: Path) -> None:
    """Doctor must produce parseable JSON and exit cleanly on a healthy host."""
    result = _run_huske(
        "doctor",
        "--json",
    )
    # Allow exit code 0 (all green) or 1 (some warnings).
    # On a CI host with no microphone, this might exit 3 — still want to assert JSON validity.
    assert result.returncode in (0, 1, 3)
    assert result.stdout.strip(), "doctor produced no stdout"
    payload = json.loads(result.stdout)
    assert "version" in payload
    assert "checks" in payload
    assert isinstance(payload["checks"], list)
    assert any(c["name"] == "Python" for c in payload["checks"])


def test_recover_with_empty_audio_root(tmp_path: Path) -> None:
    """Recover with no orphans should exit 0 quickly."""
    result = _run_huske(
        "recover",
        "--audio-root",
        str(tmp_path / "audio"),
        "--output-root",
        str(tmp_path / "transcripts"),
    )
    assert result.returncode == 0
