"""`huske llm` and `huske languages` through the Typer app — no network, no keys."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.distill import keychain


@pytest.fixture()
def env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    monkeypatch.setenv("HUSKE_APPLE_LLM_HELPER", str(tmp_path / "no-helper"))
    saved: dict[str, str] = {}
    monkeypatch.setattr(keychain, "set_key", lambda p, k: saved.__setitem__(p, k.strip()))
    monkeypatch.setattr(keychain, "has_key", lambda p: p in saved)
    monkeypatch.setattr(keychain, "get_key", lambda p: saved.get(p))
    config = tmp_path / "config.toml"
    config.write_text(f'output_root = "{tmp_path / "t"}"\n', encoding="utf-8")
    return {"runner": CliRunner(), "config": str(config), "saved": saved}


def _json(env: dict[str, Any], *args: str, stdin: str | None = None) -> tuple[int, Any]:
    result = env["runner"].invoke(app, list(args), input=stdin)
    return result.exit_code, json.loads(result.stdout)


def test_status_for_a_cloud_provider_names_every_missing_step(env: dict[str, Any]) -> None:
    code, status = _json(env, "llm", "status", "--json", "--backend", "anthropic", "--config", env["config"])
    assert code == 0
    assert status["leaves_mac"] is True and status["host"] == "api.anthropic.com"
    assert status["ready"] is False and status["reason"] == "needs_key"
    assert status["apple"]["reason"] == "no_helper"


def test_key_is_read_from_stdin_never_echoed(env: dict[str, Any]) -> None:
    code, payload = _json(env, "llm", "key", "set", "anthropic", "--json", stdin="sk-ant-xyz-123456\n")
    assert code == 0 and payload == {"provider": "anthropic", "saved": True, "error": None}
    assert env["saved"]["anthropic"] == "sk-ant-xyz-123456"
    code, status = _json(env, "llm", "status", "--json", "--backend", "anthropic", "--config", env["config"])
    assert status["key_present"] is True and status["reason"] == "needs_consent"
    assert "sk-ant-xyz-123456" not in json.dumps(status)


def test_key_for_a_provider_without_keys_is_refused(env: dict[str, Any]) -> None:
    code, payload = _json(env, "llm", "key", "set", "apple", "--json", stdin="sk-whatever-1234\n")
    assert code == 2 and payload["saved"] is False
    assert "apple" not in env["saved"]


def test_allow_cloud_records_the_configured_host_and_can_revoke(env: dict[str, Any]) -> None:
    from huske.config import load_config, update_user_config

    path = Path(env["config"])
    update_user_config({"distill_backend": "openrouter"}, config_path=path)
    code, payload = _json(env, "llm", "allow-cloud", "--yes", "--json", "--config", env["config"])
    assert code == 0 and payload["consent"] == "openrouter.ai"
    assert load_config(config_path=path).distill_cloud_consent == "openrouter.ai"
    code, payload = _json(env, "llm", "allow-cloud", "--revoke", "--json", "--config", env["config"])
    assert payload["consent"] is None
    assert load_config(config_path=path).distill_cloud_consent is None


def test_allow_cloud_needs_explicit_confirmation(env: dict[str, Any]) -> None:
    from huske.config import update_user_config

    update_user_config({"distill_backend": "openai"}, config_path=Path(env["config"]))
    code, payload = _json(env, "llm", "allow-cloud", "--json", "--config", env["config"])
    assert code == 2 and "--yes" in payload["error"]


def test_test_runs_the_synthetic_sample(env: dict[str, Any]) -> None:
    from huske.config import update_user_config

    update_user_config(
        {"distill_model": "heuristic", "language": "pt"}, config_path=Path(env["config"])
    )
    code, payload = _json(env, "llm", "test", "--json", "--config", env["config"])
    assert code == 0 and payload["ok"] is True
    assert payload["input"] == payload["output"]  # the identity backend
    assert "cubernetes" in payload["input"][0]


def test_models_without_a_key_explains_what_to_do(env: dict[str, Any]) -> None:
    code, payload = _json(env, "llm", "models", "--json", "--backend", "openai", "--config", env["config"])
    assert code == 1 and payload["models"] == []
    assert "API key" in payload["error"]


def test_languages_lists_engine_support(env: dict[str, Any]) -> None:
    code, payload = _json(env, "languages", "--json")
    rows = {r["code"]: r for r in payload["languages"]}
    assert code == 0
    assert rows["pt"] == {"code": "pt", "name": "Portuguese", "whisper": "pinned", "parakeet": "detected"}
    assert rows["ja"]["parakeet"] == "unsupported"
