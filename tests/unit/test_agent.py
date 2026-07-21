"""Tests for huske.agent — macOS LaunchAgent management."""

from __future__ import annotations

import plistlib
from dataclasses import dataclass
from pathlib import Path

import pytest

from huske import agent

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


@dataclass
class FakeResult:
    """Duck-typed stand-in for ``subprocess.CompletedProcess``."""

    returncode: int = 0
    stdout: str = ""
    stderr: str = ""


@pytest.fixture
def fake_paths(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, Path]:
    """Redirect plist + log paths into ``tmp_path`` for the duration of a test."""
    plist = tmp_path / "LaunchAgents" / "me.huske.plist"
    log_dir = tmp_path / "Logs" / "huske"
    log_out = log_dir / "agent.out.log"
    log_err = log_dir / "agent.err.log"
    monkeypatch.setattr(agent, "PLIST_PATH", plist)
    monkeypatch.setattr(agent, "LOG_DIR", log_dir)
    monkeypatch.setattr(agent, "LOG_OUT", log_out)
    monkeypatch.setattr(agent, "LOG_ERR", log_err)
    return {"plist": plist, "log_dir": log_dir, "log_out": log_out, "log_err": log_err}


@pytest.fixture
def force_macos(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(agent.platform, "system", lambda: "Darwin")


@pytest.fixture
def fake_launchctl(monkeypatch: pytest.MonkeyPatch) -> list[list[str]]:
    """Replace ``_run_launchctl`` with a recording stub. Returns the call log."""
    calls: list[list[str]] = []

    def _stub(args: list[str]) -> FakeResult:
        calls.append(args)
        return FakeResult(returncode=0)

    monkeypatch.setattr(agent, "_run_launchctl", _stub)
    return calls


# ---------------------------------------------------------------------------
# render_plist (pure)
# ---------------------------------------------------------------------------


def test_render_plist_is_valid_xml_with_expected_keys() -> None:
    xml = agent.render_plist(
        program_args=["/usr/local/bin/huske", "run", "--no-ui"],
    )
    parsed = plistlib.loads(xml.encode("utf-8"))
    assert parsed["Label"] == "me.huske"
    assert parsed["ProgramArguments"] == ["/usr/local/bin/huske", "run", "--no-ui"]
    assert parsed["RunAtLoad"] is True
    assert parsed["ProcessType"] == "Interactive"
    assert parsed["KeepAlive"] == {"SuccessfulExit": False}
    assert "PATH" in parsed["EnvironmentVariables"]
    assert "HOME" in parsed["EnvironmentVariables"]


def test_render_plist_no_keep_alive_omits_key() -> None:
    xml = agent.render_plist(
        program_args=["huske", "run"],
        keep_alive=False,
    )
    parsed = plistlib.loads(xml.encode("utf-8"))
    assert "KeepAlive" not in parsed


def test_render_plist_log_paths_propagate(tmp_path: Path) -> None:
    out = tmp_path / "out.log"
    err = tmp_path / "err.log"
    xml = agent.render_plist(
        program_args=["huske", "run"],
        log_out=out,
        log_err=err,
    )
    parsed = plistlib.loads(xml.encode("utf-8"))
    assert parsed["StandardOutPath"] == str(out)
    assert parsed["StandardErrorPath"] == str(err)


def test_render_plist_custom_path_env() -> None:
    xml = agent.render_plist(
        program_args=["huske"],
        path_env="/custom/bin:/usr/bin",
    )
    parsed = plistlib.loads(xml.encode("utf-8"))
    assert parsed["EnvironmentVariables"]["PATH"] == "/custom/bin:/usr/bin"


# ---------------------------------------------------------------------------
# build_program_args
# ---------------------------------------------------------------------------


def test_build_program_args_default() -> None:
    args = agent.build_program_args(huske_argv=["/bin/huske"])
    assert args == ["/bin/huske", "run", "--no-ui", "--log-level", "INFO"]


def test_build_program_args_with_config_resolves_to_absolute(tmp_path: Path) -> None:
    cfg = tmp_path / "config.toml"
    cfg.write_text("", encoding="utf-8")
    args = agent.build_program_args(huske_argv=["/bin/huske"], config_path=cfg)
    assert "--config" in args
    idx = args.index("--config")
    assert args[idx + 1] == str(cfg.resolve())


def test_build_program_args_log_level() -> None:
    args = agent.build_program_args(huske_argv=["/bin/huske"], log_level="DEBUG")
    assert args[-2:] == ["--log-level", "DEBUG"]


# ---------------------------------------------------------------------------
# resolve_huske_binary
# ---------------------------------------------------------------------------


def test_resolve_huske_binary_uses_which_when_found(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        agent.shutil,
        "which",
        lambda name: "/opt/homebrew/bin/huske" if name == "huske" else None,
    )
    assert agent.resolve_huske_binary() == ["/opt/homebrew/bin/huske"]


def test_resolve_huske_binary_falls_back_to_python_module(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(agent.shutil, "which", lambda name: None)
    monkeypatch.setattr(agent.sys, "executable", "/usr/bin/python3.12")
    assert agent.resolve_huske_binary() == ["/usr/bin/python3.12", "-m", "huske"]


# ---------------------------------------------------------------------------
# Platform guard
# ---------------------------------------------------------------------------


def test_ensure_macos_raises_on_linux(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(agent.platform, "system", lambda: "Linux")
    with pytest.raises(agent.UnsupportedPlatformError):
        agent._ensure_macos()


def test_install_raises_on_non_macos(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(agent.platform, "system", lambda: "Linux")
    with pytest.raises(agent.UnsupportedPlatformError):
        agent.install_agent()


def test_uninstall_raises_on_non_macos(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(agent.platform, "system", lambda: "Windows")
    with pytest.raises(agent.UnsupportedPlatformError):
        agent.uninstall_agent()


# ---------------------------------------------------------------------------
# install_agent
# ---------------------------------------------------------------------------


def test_install_agent_writes_plist_and_bootstraps(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(agent, "resolve_huske_binary", lambda: ["/opt/homebrew/bin/huske"])

    path = agent.install_agent()

    assert path == fake_paths["plist"]
    assert path.exists()
    parsed = plistlib.loads(path.read_bytes())
    assert parsed["Label"] == "me.huske"
    assert parsed["ProgramArguments"][0] == "/opt/homebrew/bin/huske"
    assert "--no-ui" in parsed["ProgramArguments"]

    assert any(call[:1] == ["bootout"] for call in fake_launchctl)
    bootstrap_calls = [c for c in fake_launchctl if c[0] == "bootstrap"]
    assert len(bootstrap_calls) == 1
    assert bootstrap_calls[0][-1] == str(fake_paths["plist"])


def test_install_agent_creates_log_directory(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(agent, "resolve_huske_binary", lambda: ["/bin/huske"])
    agent.install_agent()
    assert fake_paths["log_dir"].is_dir()


def test_install_agent_refuses_if_plist_exists(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
) -> None:
    fake_paths["plist"].parent.mkdir(parents=True)
    fake_paths["plist"].write_text("existing", encoding="utf-8")

    with pytest.raises(FileExistsError):
        agent.install_agent()


def test_install_agent_force_overwrites_existing(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_paths["plist"].parent.mkdir(parents=True)
    fake_paths["plist"].write_text("existing", encoding="utf-8")
    monkeypatch.setattr(agent, "resolve_huske_binary", lambda: ["/bin/huske"])

    path = agent.install_agent(force=True)

    parsed = plistlib.loads(path.read_bytes())
    assert parsed["Label"] == "me.huske"


def test_install_agent_raises_on_bootstrap_failure(
    fake_paths: dict[str, Path],
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(agent, "resolve_huske_binary", lambda: ["/bin/huske"])

    def _stub(args: list[str]) -> FakeResult:
        if args and args[0] == "bootstrap":
            return FakeResult(returncode=5, stderr="Input/output error")
        return FakeResult(returncode=0)

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    with pytest.raises(RuntimeError, match="bootstrap failed"):
        agent.install_agent()


def test_install_agent_propagates_keep_alive_setting(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(agent, "resolve_huske_binary", lambda: ["/bin/huske"])

    agent.install_agent(keep_alive=False)
    parsed = plistlib.loads(fake_paths["plist"].read_bytes())
    assert "KeepAlive" not in parsed


def test_install_agent_includes_config_path(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    cfg = tmp_path / "config.toml"
    cfg.write_text("", encoding="utf-8")
    monkeypatch.setattr(agent, "resolve_huske_binary", lambda: ["/bin/huske"])

    agent.install_agent(config_path=cfg)
    parsed = plistlib.loads(fake_paths["plist"].read_bytes())
    args = parsed["ProgramArguments"]
    assert "--config" in args
    assert args[args.index("--config") + 1] == str(cfg.resolve())


# ---------------------------------------------------------------------------
# uninstall_agent
# ---------------------------------------------------------------------------


def test_uninstall_agent_bootouts_and_removes_plist(
    fake_paths: dict[str, Path],
    force_macos: None,
    fake_launchctl: list[list[str]],
) -> None:
    fake_paths["plist"].parent.mkdir(parents=True)
    fake_paths["plist"].write_text("plist", encoding="utf-8")

    removed = agent.uninstall_agent()

    assert removed is True
    assert not fake_paths["plist"].exists()
    assert any(call[:1] == ["bootout"] for call in fake_launchctl)


def test_uninstall_agent_returns_false_when_nothing_to_do(
    fake_paths: dict[str, Path],
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _stub(args: list[str]) -> FakeResult:
        return FakeResult(returncode=113, stderr="Could not find service")

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    removed = agent.uninstall_agent()
    assert removed is False


# ---------------------------------------------------------------------------
# agent_status
# ---------------------------------------------------------------------------


def test_agent_status_when_loaded_parses_pid_and_exit(
    fake_paths: dict[str, Path],
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_paths["plist"].parent.mkdir(parents=True)
    fake_paths["plist"].write_text("plist", encoding="utf-8")

    print_output = (
        "gui/501/me.huske = {\n"
        "    active count = 1\n"
        "    state = running\n"
        "    pid = 12345\n"
        "    last exit code = 0\n"
        "}\n"
    )

    def _stub(args: list[str]) -> FakeResult:
        if args and args[0] == "print":
            return FakeResult(returncode=0, stdout=print_output)
        return FakeResult(returncode=0)

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    status = agent.agent_status()
    assert status.installed is True
    assert status.loaded is True
    assert status.pid == 12345
    assert status.last_exit_code == 0
    assert status.plist_path == fake_paths["plist"]


def test_agent_status_when_not_loaded(
    fake_paths: dict[str, Path],
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _stub(args: list[str]) -> FakeResult:
        return FakeResult(returncode=113, stderr="Could not find service")

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    status = agent.agent_status()
    assert status.installed is False
    assert status.loaded is False
    assert status.pid is None
    assert status.last_exit_code is None


# ---------------------------------------------------------------------------
# start_agent / stop_agent
# ---------------------------------------------------------------------------


def test_start_agent_kickstarts(
    force_macos: None,
    fake_launchctl: list[list[str]],
) -> None:
    agent.start_agent()
    assert any(call[0] == "kickstart" for call in fake_launchctl)


def test_stop_agent_sends_sigterm(
    force_macos: None,
    fake_launchctl: list[list[str]],
) -> None:
    assert agent.stop_agent() is True
    assert any(call[:2] == ["kill", "TERM"] for call in fake_launchctl)


def test_stop_agent_is_noop_when_already_stopped(
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _stub(args: list[str]) -> FakeResult:
        return FakeResult(returncode=3, stderr="No process to signal.")

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    assert agent.stop_agent() is False


def test_start_agent_raises_on_failure(
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _stub(args: list[str]) -> FakeResult:
        return FakeResult(returncode=1, stderr="kickstart broke")

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    with pytest.raises(RuntimeError, match="kickstart broke"):
        agent.start_agent()


def test_stop_agent_raises_on_failure(
    force_macos: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _stub(args: list[str]) -> FakeResult:
        return FakeResult(returncode=1, stderr="kill failed")

    monkeypatch.setattr(agent, "_run_launchctl", _stub)

    with pytest.raises(RuntimeError, match="kill failed"):
        agent.stop_agent()
