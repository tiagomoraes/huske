"""Tests for huske.update_check."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from huske import update_check

# ---------------------------------------------------------------------------
# Version parsing / comparison
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("0.1.0", (0, 1, 0)),
        ("0.2.3", (0, 2, 3)),
        ("v1.2.3", (1, 2, 3)),
        ("1.2.3rc1", (1, 2, 3)),
        ("1.2.3.dev4", (1, 2, 3)),
        ("  1.0  ", (1, 0)),
        ("not-a-version", (0,)),
        ("", (0,)),
    ],
)
def test_parse_version(raw: str, expected: tuple[int, ...]) -> None:
    assert update_check._parse_version(raw) == expected


@pytest.mark.parametrize(
    ("latest", "current", "expected"),
    [
        ("0.2.0", "0.1.0", True),
        ("1.0.0", "0.99.99", True),
        ("0.1.0", "0.1.0", False),
        ("0.1.0", "0.2.0", False),
        ("0.10.0", "0.9.9", True),  # numeric, not lexical
    ],
)
def test_is_newer(latest: str, current: str, expected: bool) -> None:
    assert update_check._is_newer(latest, current) is expected


# ---------------------------------------------------------------------------
# Install-method detection
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("exe", "expected"),
    [
        ("/opt/homebrew/Cellar/huske/0.1.0/libexec/bin/python3.11", "brew"),
        ("/usr/local/Cellar/huske/0.1.0/libexec/bin/python3.11", "brew"),
        ("/home/linuxbrew/.linuxbrew/Cellar/huske/0.1.0/libexec/bin/python", "brew"),
        ("/Users/me/Library/Application Support/uv/tools/huske/bin/python", "uv"),
        ("/home/me/.local/share/uv/tools/huske/bin/python", "uv"),
        ("/Users/me/.local/pipx/venvs/huske/bin/python", "pipx"),
        ("/Users/me/.local/share/pipx/venvs/huske/bin/python", "pipx"),
        ("/Users/me/code/huske/.venv/bin/python", "unknown"),
        ("/usr/bin/python3", "unknown"),
    ],
)
def test_detect_install_method(
    exe: str, expected: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(update_check.sys, "executable", exe)
    assert update_check._detect_install_method() == expected


def test_detect_install_method_uses_unresolved_path_for_pipx(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Regression: a pipx venv whose ``bin/python`` symlinks to a Homebrew
    Python must still be detected as pipx, not brew.

    Earlier the detector called ``Path.resolve()`` on ``sys.executable``,
    which followed the symlink into ``/opt/homebrew/Cellar/python@…/…`` and
    misclassified the install. The detector must use the unresolved path so
    the enclosing ``pipx/venvs`` directory is preserved.
    """
    target = tmp_path / "homebrew" / "Cellar" / "python@3.11" / "3.11.7" / "bin" / "python3.11"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    target.chmod(0o755)

    venv_python = tmp_path / "pipx" / "venvs" / "huske" / "bin" / "python"
    venv_python.parent.mkdir(parents=True, exist_ok=True)
    venv_python.symlink_to(target)
    # Sanity check: resolving really would have taken us into Cellar.
    assert "Cellar" in str(venv_python.resolve())

    monkeypatch.setattr(update_check.sys, "executable", str(venv_python))
    assert update_check._detect_install_method() == "pipx"


def test_detect_install_method_uses_unresolved_path_for_uv(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Same as the pipx case, for an ``uv tool`` install with a symlinked
    base interpreter."""
    target = tmp_path / "homebrew" / "Cellar" / "python@3.12" / "3.12.5" / "bin" / "python3.12"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    target.chmod(0o755)

    venv_python = tmp_path / "uv" / "tools" / "huske" / "bin" / "python"
    venv_python.parent.mkdir(parents=True, exist_ok=True)
    venv_python.symlink_to(target)
    assert "Cellar" in str(venv_python.resolve())

    monkeypatch.setattr(update_check.sys, "executable", str(venv_python))
    assert update_check._detect_install_method() == "uv"


# ---------------------------------------------------------------------------
# Cache round-trip
# ---------------------------------------------------------------------------


def _use_cache_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    cache = tmp_path / "update-check.json"
    monkeypatch.setenv("HUSKE_UPDATE_CHECK_CACHE", str(cache))
    return cache


def test_cache_round_trip(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    cache = _use_cache_dir(tmp_path, monkeypatch)
    update_check._save_cache("9.9.9")
    loaded = update_check._load_cache()
    assert loaded is not None
    assert loaded["latest_version"] == "9.9.9"
    assert "checked_at" in loaded
    assert cache.exists()


def test_load_cache_missing_returns_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _use_cache_dir(tmp_path, monkeypatch)
    assert update_check._load_cache() is None


def test_load_cache_corrupted_returns_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cache = _use_cache_dir(tmp_path, monkeypatch)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text("not json", encoding="utf-8")
    assert update_check._load_cache() is None


@pytest.mark.parametrize(
    ("cached", "expected_stale"),
    [
        (None, True),
        ({}, True),
        ({"checked_at": "garbage"}, True),
        (
            {
                "checked_at": (
                    datetime.now(UTC) - timedelta(hours=25)
                ).isoformat()
            },
            True,
        ),
        (
            {
                "checked_at": (
                    datetime.now(UTC) - timedelta(minutes=5)
                ).isoformat()
            },
            False,
        ),
    ],
)
def test_cache_is_stale(cached: dict[str, Any] | None, expected_stale: bool) -> None:
    assert update_check._cache_is_stale(cached) is expected_stale


# ---------------------------------------------------------------------------
# Opt-out / TTY / editable detection
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [("1", True), ("true", True), ("YES", True), ("on", True), ("0", False), ("", False)],
)
def test_is_disabled_env(
    value: str, expected: bool, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HUSKE_NO_UPDATE_CHECK", value)
    assert update_check._is_disabled() is expected


def test_is_disabled_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HUSKE_NO_UPDATE_CHECK", raising=False)
    assert update_check._is_disabled() is False


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------


def test_fetch_latest_version_from_fixture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = tmp_path / "pypi.json"
    fixture.write_text(
        json.dumps({"info": {"version": "9.9.9"}}), encoding="utf-8"
    )
    monkeypatch.setenv("HUSKE_UPDATE_CHECK_URL", fixture.as_uri())
    assert update_check._fetch_latest_version() == "9.9.9"


def test_fetch_latest_version_missing_field_returns_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = tmp_path / "pypi.json"
    fixture.write_text(json.dumps({"info": {}}), encoding="utf-8")
    monkeypatch.setenv("HUSKE_UPDATE_CHECK_URL", fixture.as_uri())
    assert update_check._fetch_latest_version() is None


def test_fetch_latest_version_bad_json_returns_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = tmp_path / "pypi.json"
    fixture.write_text("{not json", encoding="utf-8")
    monkeypatch.setenv("HUSKE_UPDATE_CHECK_URL", fixture.as_uri())
    assert update_check._fetch_latest_version() is None


def test_fetch_latest_version_unreachable_returns_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(
        "HUSKE_UPDATE_CHECK_URL", (tmp_path / "does-not-exist").as_uri()
    )
    assert update_check._fetch_latest_version() is None


# ---------------------------------------------------------------------------
# notify_if_outdated integration
# ---------------------------------------------------------------------------
#
# These tests intentionally avoid monkeypatching ``sys.stderr``: pytest's
# default fd-level capture wraps stderr in a way that interacts badly with
# such replacements. Instead we stub ``_stderr_is_tty`` and ``_print_banner``
# directly and assert against captured arguments — the banner content itself
# is exercised by ``test_print_banner_*`` below.


@pytest.fixture
def banner_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> list[tuple[str, str]]:
    """Force a clean cache, non-editable install, and TTY stderr.

    Returns a list that captures ``(current, latest)`` for every banner the
    function would have printed during the test.
    """
    _use_cache_dir(tmp_path, monkeypatch)
    monkeypatch.delenv("HUSKE_NO_UPDATE_CHECK", raising=False)
    monkeypatch.setattr(update_check, "_is_editable_install", lambda: False)
    monkeypatch.setattr(update_check, "_stderr_is_tty", lambda: True)
    monkeypatch.setattr(
        update_check.sys,
        "executable",
        "/Users/me/.local/share/uv/tools/huske/bin/python",
    )
    monkeypatch.setattr(update_check, "_spawn_refresh", lambda: None)

    printed: list[tuple[str, str]] = []
    monkeypatch.setattr(
        update_check,
        "_print_banner",
        lambda current, latest: printed.append((current, latest)),
    )
    return printed


def test_notify_prints_banner_when_outdated(
    banner_env: list[tuple[str, str]],
) -> None:
    update_check._save_cache("9.9.9")

    update_check.notify_if_outdated()

    assert banner_env == [(update_check.__version__, "9.9.9")]


def test_notify_silent_when_up_to_date(
    banner_env: list[tuple[str, str]],
) -> None:
    update_check._save_cache(update_check.__version__)

    update_check.notify_if_outdated()

    assert banner_env == []


def test_notify_silent_when_disabled(
    banner_env: list[tuple[str, str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    update_check._save_cache("9.9.9")
    monkeypatch.setenv("HUSKE_NO_UPDATE_CHECK", "1")

    update_check.notify_if_outdated()

    assert banner_env == []


def test_notify_silent_when_editable(
    banner_env: list[tuple[str, str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    update_check._save_cache("9.9.9")
    monkeypatch.setattr(update_check, "_is_editable_install", lambda: True)

    update_check.notify_if_outdated()

    assert banner_env == []


def test_notify_silent_when_stderr_not_tty(
    banner_env: list[tuple[str, str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    update_check._save_cache("9.9.9")
    monkeypatch.setattr(update_check, "_stderr_is_tty", lambda: False)

    update_check.notify_if_outdated()

    assert banner_env == []


def test_notify_refreshes_cache_when_stale(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A stale (or empty) cache must trigger a background refresh."""
    _use_cache_dir(tmp_path, monkeypatch)
    monkeypatch.delenv("HUSKE_NO_UPDATE_CHECK", raising=False)
    monkeypatch.setattr(update_check, "_is_editable_install", lambda: False)
    monkeypatch.setattr(update_check, "_stderr_is_tty", lambda: True)
    monkeypatch.setattr(update_check, "_print_banner", lambda *_a, **_kw: None)

    called: list[bool] = []
    monkeypatch.setattr(
        update_check, "_spawn_refresh", lambda: called.append(True)
    )

    update_check.notify_if_outdated()

    assert called == [True]


def test_notify_skips_refresh_when_cache_fresh(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _use_cache_dir(tmp_path, monkeypatch)
    monkeypatch.delenv("HUSKE_NO_UPDATE_CHECK", raising=False)
    monkeypatch.setattr(update_check, "_is_editable_install", lambda: False)
    monkeypatch.setattr(update_check, "_stderr_is_tty", lambda: True)
    monkeypatch.setattr(update_check, "_print_banner", lambda *_a, **_kw: None)

    update_check._save_cache(update_check.__version__)

    called: list[bool] = []
    monkeypatch.setattr(
        update_check, "_spawn_refresh", lambda: called.append(True)
    )

    update_check.notify_if_outdated()

    assert called == []


# ---------------------------------------------------------------------------
# Banner rendering
# ---------------------------------------------------------------------------


def test_print_banner_known_install_method(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(update_check, "_detect_install_method", lambda: "uv")

    update_check._print_banner("0.1.0", "9.9.9")

    err = capsys.readouterr().err
    assert "9.9.9" in err
    assert "0.1.0" in err
    assert "uv tool upgrade huske" in err
    assert "HUSKE_NO_UPDATE_CHECK" in err


def test_print_banner_unknown_install_method_lists_all(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(update_check, "_detect_install_method", lambda: "unknown")

    update_check._print_banner("0.1.0", "9.9.9")

    err = capsys.readouterr().err
    for cmd in update_check._UPGRADE_COMMANDS.values():
        assert cmd in err
