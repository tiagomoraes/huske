"""`huske models` through the Typer app — no network, no model weights."""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import numpy as np
import pytest
import soundfile as sf
from typer.testing import CliRunner

from huske.cli import app
from huske.config import load_config
from huske.transcribe import catalog, models_cli
from huske.transcribe.engines import FAMILIES, EngineFamily, Segment, register_family
from huske.transcribe.engines.base import TranscriptionEngine


@pytest.fixture()
def env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    monkeypatch.setattr(models_cli, "is_downloaded", lambda spec: spec.id == "whisper-tiny")
    # No network: an ad-hoc repo "lists" a loadable layout unless a test says otherwise.
    monkeypatch.setattr(catalog, "layout_problem", lambda spec, files=None: None)
    config = tmp_path / "config.toml"
    config.write_text('language = "pt"\n', encoding="utf-8")
    return {"runner": CliRunner(), "config": config}


def _run(env: dict[str, Any], *args: str) -> tuple[int, Any]:
    result = env["runner"].invoke(app, [*args, "--config", str(env["config"])])
    try:
        return result.exit_code, json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return result.exit_code, result.stdout


def test_list_json_marks_the_model_in_use(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "--json")
    assert code == 0
    assert payload["current"]["id"] == "parakeet-tdt-0.6b-v3"
    rows = {m["id"]: m for m in payload["models"]}
    assert rows["parakeet-tdt-0.6b-v3"]["in_use"] is True
    assert rows["whisper-large-v3-turbo"]["in_use"] is False
    assert rows["whisper-large-v3-turbo"]["pins_language"] is True
    assert rows["whisper-tiny"]["downloaded"] is True
    assert {f["name"] for f in payload["families"]} >= {"parakeet", "whisper"}


def test_list_human_table_names_every_model(env: dict[str, Any]) -> None:
    code, out = _run(env, "models")
    assert code == 0
    for model in catalog.models():
        assert model.id in out
    assert "● in use: Parakeet v3" in out


def test_use_writes_the_model_and_its_legacy_keys(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "use", "whisper-large-v3-turbo", "--json")
    assert code == 0
    assert payload["written"] == {
        "asr_model": "whisper-large-v3-turbo",
        "asr_engine": "whisper",
        "model": "large-v3-turbo",
    }
    cfg = load_config(config_path=env["config"])
    assert cfg.asr_model == "whisper-large-v3-turbo" and cfg.language == "pt"


def test_use_warns_when_the_language_is_not_covered(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "use", "parakeet-tdt-0.6b-v2", "--json")
    assert code == 0
    assert any("doesn't transcribe 'pt'" in n for n in payload["notes"])
    assert "language_unsupported" in payload["note_codes"]
    assert len(payload["note_codes"]) == len(payload["notes"])


def test_use_refuses_a_repo_in_the_wrong_format(
    env: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        catalog, "layout_problem",
        lambda spec, files=None: f"{spec.repo} isn't in the format Whisper loads",
    )
    code, payload = _run(env, "models", "use", "openai/whisper-large-v3", "--json")
    assert code == 2 and "format" in payload["error"]
    assert load_config(config_path=env["config"]).asr_model is None


def test_download_refusals_keep_the_event_shape(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "download", "nope", "--json")
    assert code == 2 and payload["event"] == "error" and payload["error"]


def test_use_rejects_unknown_models_and_needs_a_name_without_a_terminal(
    env: dict[str, Any],
) -> None:
    code, payload = _run(env, "models", "use", "someone/mystery-asr", "--json")
    assert code == 2 and "which engine" in payload["error"]
    code, payload = _run(env, "models", "use", "--json")
    assert code == 2


def test_use_accepts_a_new_repo_of_a_known_family(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "use", "someone/parakeet-tdt-0.6b-v9", "--json")
    assert code == 0
    assert payload["model"]["in_catalog"] is False
    assert payload["written"]["asr_model"] == "someone/parakeet-tdt-0.6b-v9"


def test_info_json(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "info", "whisper-large-v3-turbo-q4", "--json")
    assert code == 0
    assert payload["repo"] == "mlx-community/whisper-large-v3-turbo-q4"
    assert payload["dictionary"] == "prompt"
    assert payload["size_mb"] == 464


def test_download_streams_progress_lines(env: dict[str, Any], monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_download(spec: Any, on_progress: Any) -> Path:
        on_progress(10, 100)
        on_progress(100, 100)
        return Path("/tmp")

    monkeypatch.setattr(models_cli, "download", fake_download)
    result = env["runner"].invoke(
        app, ["models", "download", "whisper-base", "--json", "--config", str(env["config"])]
    )
    lines = [json.loads(line) for line in result.stdout.strip().splitlines()]
    assert result.exit_code == 0
    assert [e["event"] for e in lines] == ["progress", "progress", "done"]
    assert lines[1]["bytes"] == lines[1]["total"] == 100


def test_download_of_a_cached_model_is_a_no_op(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "download", "whisper-tiny", "--json")
    assert code == 0 and payload == {
        "event": "done", "id": "whisper-tiny", "already": True, "error": None
    }


class _EchoEngine(TranscriptionEngine):
    model_label = "fake:echo"

    def transcribe(self, audio: Any) -> list[Segment]:
        return [Segment(start=0.0, end=audio.size / 16000, text="olá pessoal")]


@pytest.fixture()
def fake_family() -> Iterator[None]:
    register_family(
        EngineFamily(
            name="fakeasr",
            label="Fake",
            label_prefix="fakeasr",
            pins_language=True,
            dictionary="none",
            runtime="json",
            builder=lambda repo, label, language, ct: _EchoEngine(),
        )
    )
    yield
    FAMILIES.pop("fakeasr", None)


def test_try_reports_speed_on_given_audio(
    env: dict[str, Any], tmp_path: Path, fake_family: None
) -> None:
    wav = tmp_path / "clip.wav"
    sf.write(wav, np.zeros(16000 * 4, dtype=np.float32), 16000)
    code, payload = _run(env, "models", "try", "someone/fakeasr-v1", "--audio", str(wav), "--json")
    assert code == 0 and payload["ok"] is True
    assert payload["audio_seconds"] == 4.0
    assert payload["text"] == "olá pessoal"
    assert payload["x_realtime"] > 0
    assert payload["synthetic"] is False


def test_convert_writes_into_models_root(
    env: dict[str, Any], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from huske.config import update_user_config
    from huske.transcribe import convert

    update_user_config({"models_root": str(tmp_path / "models")}, config_path=env["config"])
    seen: dict[str, Any] = {}

    def fake_fetch(repo: str, out: Path, on_progress: Any = None) -> Path:
        seen.update(repo=repo, out=out)
        on_progress(5, 10)
        return out

    monkeypatch.setattr(convert, "fetch_and_convert", fake_fetch)
    result = env["runner"].invoke(
        app, ["models", "convert", "someone/whisper-ptbr", "--json", "--config", str(env["config"])]
    )
    lines = [json.loads(line) for line in result.stdout.strip().splitlines()]
    assert result.exit_code == 0
    assert seen["out"] == tmp_path / "models" / "whisper-ptbr"
    assert lines[-1]["event"] == "done" and lines[-1]["path"].endswith("whisper-ptbr")


def test_convert_rejects_an_unsafe_folder_name(env: dict[str, Any]) -> None:
    code, payload = _run(env, "models", "convert", "a/b", "--name", "../escape", "--json")
    assert code == 2 and payload["event"] == "error"


def test_use_of_a_transformers_whisper_says_it_needs_conversion(
    env: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        catalog, "layout_problem",
        lambda spec, files=None: f"{spec.repo} is a transformers checkpoint; convert it first: "
        f"huske models convert {spec.repo}",
    )
    code, payload = _run(env, "models", "use", "someone/whisper-large-v3-pt", "--json")
    assert code == 2
    assert payload["code"] == "needs_conversion" and payload["repo"] == "someone/whisper-large-v3-pt"
