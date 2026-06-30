"""Best-effort Ollama auto-management used when distillation turns on."""

from __future__ import annotations

import pytest

from huske.distill import client as client_mod
from huske.distill import ollama_manage
from huske.distill.health import Readiness

# ---------------------------------------------------------------------------
# CLI / daemon probing
# ---------------------------------------------------------------------------


def test_ollama_cli_found_and_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ollama_manage.shutil, "which", lambda _n: "/usr/local/bin/ollama")
    assert ollama_manage.ollama_cli() == "/usr/local/bin/ollama"
    monkeypatch.setattr(ollama_manage.shutil, "which", lambda _n: None)
    assert ollama_manage.ollama_cli() is None


def test_daemon_reachable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(client_mod.OllamaClient, "list_models", lambda self: ["x"])
    assert ollama_manage.daemon_reachable("http://127.0.0.1:11434") is True

    def boom(self: object) -> list[str]:
        raise client_mod.DistillError("connection refused")

    monkeypatch.setattr(client_mod.OllamaClient, "list_models", boom)
    assert ollama_manage.daemon_reachable("http://127.0.0.1:11434") is False


# ---------------------------------------------------------------------------
# start_daemon
# ---------------------------------------------------------------------------


def test_start_daemon_noop_when_already_running(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ollama_manage, "daemon_reachable", lambda _ep, **_k: True)

    def fail_popen(*_a: object, **_k: object) -> object:
        pytest.fail("must not spawn `ollama serve` when the daemon is already up")

    monkeypatch.setattr(ollama_manage.subprocess, "Popen", fail_popen)
    assert ollama_manage.start_daemon("http://127.0.0.1:11434") is True


def test_start_daemon_false_without_cli(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ollama_manage, "daemon_reachable", lambda _ep, **_k: False)
    monkeypatch.setattr(ollama_manage, "ollama_cli", lambda: None)
    assert ollama_manage.start_daemon("http://127.0.0.1:11434") is False


# ---------------------------------------------------------------------------
# pull progress
# ---------------------------------------------------------------------------


def test_progress_emitter_reports_percentage() -> None:
    events: list[tuple[str, str]] = []
    cb = ollama_manage._progress_emitter(
        lambda s, m: events.append((s, m)), "qwen3.5:0.8b", None, interval=0.0
    )
    cb("downloading", 50, 100)
    assert events and "50%" in events[-1][1]


def test_progress_emitter_aborts_when_asked() -> None:
    cb = ollama_manage._progress_emitter(None, "qwen3.5:0.8b", lambda: True)
    with pytest.raises(ollama_manage.PullAborted):
        cb("downloading", 1, 2)


# ---------------------------------------------------------------------------
# ensure_ready orchestration
# ---------------------------------------------------------------------------


def _seq(*readinesses: Readiness):  # type: ignore[no-untyped-def]
    it = iter(readinesses)
    return lambda *_a, **_k: next(it)


def test_ensure_ready_returns_probe_when_already_ready(monkeypatch: pytest.MonkeyPatch) -> None:
    ready = Readiness(True, "ready", reason="ready")
    monkeypatch.setattr(ollama_manage, "probe_distill", _seq(ready))
    assert ollama_manage.ensure_ready("qwen3.5:0.8b") is ready


def test_ensure_ready_skips_management_when_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    down = Readiness(False, "unreachable", "hint", reason="unreachable")
    monkeypatch.setattr(ollama_manage, "probe_distill", _seq(down))
    started: list[int] = []
    monkeypatch.setattr(ollama_manage, "start_daemon", lambda *_a, **_k: started.append(1) or True)
    assert ollama_manage.ensure_ready("qwen3.5:0.8b", auto_manage=False) is down
    assert started == []


def test_ensure_ready_no_cli_does_not_attempt_start(monkeypatch: pytest.MonkeyPatch) -> None:
    down = Readiness(False, "unreachable", "hint", reason="unreachable")
    monkeypatch.setattr(ollama_manage, "probe_distill", _seq(down))
    monkeypatch.setattr(ollama_manage, "ollama_cli", lambda: None)
    started: list[int] = []
    monkeypatch.setattr(ollama_manage, "start_daemon", lambda *_a, **_k: started.append(1) or True)
    assert ollama_manage.ensure_ready("qwen3.5:0.8b") is down
    assert started == []


def test_ensure_ready_starts_daemon_then_pulls_model(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        ollama_manage,
        "probe_distill",
        _seq(
            Readiness(False, "unreachable", "h", reason="unreachable"),  # initial
            Readiness(False, "missing", "h", reason="model_missing"),  # after start
            Readiness(True, "ready", reason="ready"),  # after pull
        ),
    )
    monkeypatch.setattr(ollama_manage, "ollama_cli", lambda: "/usr/local/bin/ollama")
    monkeypatch.setattr(ollama_manage, "start_daemon", lambda *_a, **_k: True)
    pulled: list[str] = []
    monkeypatch.setattr(ollama_manage, "pull_model", lambda _ep, model, **_k: pulled.append(model))

    events: list[tuple[str, str]] = []
    r = ollama_manage.ensure_ready("qwen3.5:0.8b", emit=lambda s, m: events.append((s, m)))

    assert r.ok
    assert pulled == ["qwen3.5:0.8b"]
    msgs = " ".join(m for _s, m in events)
    assert "starting ollama" in msgs and "pulled" in msgs


def test_ensure_ready_surfaces_pull_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        ollama_manage,
        "probe_distill",
        _seq(
            Readiness(False, "missing", "h", reason="model_missing"),  # initial
            Readiness(False, "missing", "h", reason="model_missing"),  # re-probe after fail
        ),
    )

    def boom(_ep: str, _model: str, **_k: object) -> None:
        raise client_mod.DistillError("registry unreachable")

    monkeypatch.setattr(ollama_manage, "pull_model", boom)
    events: list[tuple[str, str]] = []
    r = ollama_manage.ensure_ready("qwen3.5:0.8b", emit=lambda s, m: events.append((s, m)))
    assert not r.ok
    assert any("pull failed" in m for _s, m in events)


# ---------------------------------------------------------------------------
# OllamaClient.pull streaming
# ---------------------------------------------------------------------------


class _FakeResp:
    def __init__(self, lines: list[bytes]) -> None:
        self._lines = lines

    def __enter__(self):  # type: ignore[no-untyped-def]
        return iter(self._lines)

    def __exit__(self, *_a: object) -> bool:
        return False


def test_pull_streams_progress(monkeypatch: pytest.MonkeyPatch) -> None:
    lines = [
        b'{"status":"pulling manifest"}\n',
        b'{"status":"downloading","completed":5,"total":10}\n',
        b'{"status":"success"}\n',
    ]
    monkeypatch.setattr(
        client_mod.urllib.request, "urlopen", lambda _req, timeout=None: _FakeResp(lines)
    )
    progress: list[tuple[str, int, int]] = []
    client_mod.OllamaClient("http://127.0.0.1:11434").pull(
        "qwen3.5:0.8b", on_progress=lambda s, c, t: progress.append((s, c, t))
    )
    assert ("downloading", 5, 10) in progress


def test_pull_raises_on_daemon_error(monkeypatch: pytest.MonkeyPatch) -> None:
    lines = [b'{"status":"pulling"}\n', b'{"error":"model not found"}\n']
    monkeypatch.setattr(
        client_mod.urllib.request, "urlopen", lambda _req, timeout=None: _FakeResp(lines)
    )
    with pytest.raises(client_mod.DistillError):
        client_mod.OllamaClient("http://127.0.0.1:11434").pull("nope")
