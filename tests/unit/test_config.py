"""Tests for huske.config."""

from __future__ import annotations

import platform
from pathlib import Path

import pytest

from huske.config import RuntimeConfig, load_config, update_user_config


def test_defaults_are_sane() -> None:
    cfg = RuntimeConfig()
    # chunk_minutes is now a safety cap, not the usual boundary — chunks split
    # on real pauses (speech_gated / silence_split_seconds).
    assert cfg.chunk_minutes == 15.0
    assert cfg.speech_gated is True
    assert cfg.silence_split_seconds == 60.0
    assert cfg.echo_cancel is True
    assert cfg.asr_engine == "parakeet"
    assert cfg.parakeet_model == "mlx-community/parakeet-tdt-0.6b-v3"
    assert cfg.echo_dedup == "drop"
    assert cfg.model == "base"
    assert cfg.compute_type == "int8"
    assert cfg.device == "auto"
    assert cfg.language is None
    assert cfg.sample_rate == 48000
    assert cfg.channels == 2
    assert cfg.chunk_seconds == 900.0


def test_distill_defaults_are_light_and_opt_in() -> None:
    cfg = RuntimeConfig()
    assert cfg.distill_enabled is False  # opt-in; never on by default
    assert cfg.distill_backend == "mlx"  # built-in: no external daemon
    # Tiny correction model — not a 4B statement extractor.
    assert cfg.distill_model is None  # resolved per backend (huske.distill.providers)
    assert cfg.distill_think is False  # non-reasoning distillation by default


def test_distill_model_is_selectable(tmp_path: Path) -> None:
    # A different local tag can be chosen via config file or CLI override.
    cfg_file = tmp_path / "config.toml"
    cfg_file.write_text('distill_model = "qwen3.5:0.8b-mlx"\n', encoding="utf-8")
    assert load_config(config_path=cfg_file).distill_model == "qwen3.5:0.8b-mlx"
    overridden = load_config(
        config_path=cfg_file, cli_overrides={"distill_model": "qwen3.5:4b"}
    )
    assert overridden.distill_model == "qwen3.5:4b"


def test_keep_audio_format_default_and_validation() -> None:
    assert RuntimeConfig().keep_audio_format == "opus"  # compressed by default
    RuntimeConfig(keep_audio_format="flac")
    RuntimeConfig(keep_audio_format="wav")
    with pytest.raises(ValueError):
        RuntimeConfig(keep_audio_format="mp3")  # type: ignore[arg-type]


def test_chunk_minutes_range() -> None:
    with pytest.raises(ValueError):
        RuntimeConfig(chunk_minutes=0.0)
    with pytest.raises(ValueError):
        RuntimeConfig(chunk_minutes=61.0)


def test_unknown_model_rejected() -> None:
    with pytest.raises(ValueError):
        RuntimeConfig(model="huge")  # type: ignore[arg-type]


def test_paths_expand_user(tmp_path: Path) -> None:
    cfg = RuntimeConfig(output_root="~/x")
    assert cfg.output_root.is_absolute()
    assert "~" not in str(cfg.output_root)


def test_cuda_rejected_on_mac() -> None:
    if platform.system() != "Darwin":
        pytest.skip("only meaningful on macOS")
    with pytest.raises(ValueError):
        RuntimeConfig(device="cuda")


def test_load_config_uses_toml(tmp_path: Path) -> None:
    cfg_file = tmp_path / "config.toml"
    cfg_file.write_text(
        'chunk_minutes = 5\nmodel = "tiny"\nlanguage = "pt"\n', encoding="utf-8"
    )
    cfg = load_config(config_path=cfg_file)
    assert cfg.chunk_minutes == 5.0
    assert cfg.model == "tiny"
    assert cfg.language == "pt"


def test_load_config_cli_overrides_win(tmp_path: Path) -> None:
    cfg_file = tmp_path / "c.toml"
    cfg_file.write_text('chunk_minutes = 5\nmodel = "tiny"\n', encoding="utf-8")
    cfg = load_config(config_path=cfg_file, cli_overrides={"model": "small"})
    assert cfg.chunk_minutes == 5.0
    assert cfg.model == "small"


def test_load_config_missing_toml_uses_defaults(tmp_path: Path) -> None:
    cfg = load_config(config_path=tmp_path / "missing.toml")
    assert cfg.chunk_minutes == 15.0


def test_footprint_defaults_cap_metal() -> None:
    cfg = RuntimeConfig()
    assert cfg.recycle_idle_process is True
    assert cfg.metal_cache_limit_mb == 512
    assert cfg.metal_memory_limit_mb == 8192


def test_unknown_field_rejected() -> None:
    with pytest.raises(ValueError):
        RuntimeConfig(nonsense=True)  # type: ignore[call-arg]


def test_update_user_config_creates_file(tmp_path: Path) -> None:
    target = tmp_path / "missing" / "config.toml"
    written = update_user_config({"input_device": "MacBook Pro Microphone"}, target)
    assert written == target
    cfg = load_config(config_path=target)
    assert cfg.input_device == "MacBook Pro Microphone"


def test_update_user_config_preserves_other_keys(tmp_path: Path) -> None:
    target = tmp_path / "config.toml"
    target.write_text(
        'chunk_minutes = 5\nmodel = "tiny"\nlanguage = "pt"\n', encoding="utf-8"
    )
    update_user_config({"input_device": "Built-in"}, target)
    cfg = load_config(config_path=target)
    assert cfg.chunk_minutes == 5.0
    assert cfg.model == "tiny"
    assert cfg.language == "pt"
    assert cfg.input_device == "Built-in"


def test_update_user_config_clears_with_none(tmp_path: Path) -> None:
    target = tmp_path / "config.toml"
    target.write_text(
        'input_device = "Old Device"\nmodel = "small"\n', encoding="utf-8"
    )
    update_user_config({"input_device": None}, target)
    cfg = load_config(config_path=target)
    assert cfg.input_device is None
    assert cfg.model == "small"


def test_run_does_not_override_config_keep_audio(monkeypatch, tmp_path) -> None:
    """`keep_audio = true` in the config survives `huske run` without flags."""
    from typer.testing import CliRunner

    import huske.cli as cli
    import huske.run_loop as run_loop

    seen: dict[str, object] = {}

    def fake_run_session(*args: object, **kwargs: object) -> int:
        from huske.config import load_config

        cfg = load_config(kwargs.get("config_path"), kwargs.get("cli_overrides"))  # type: ignore[arg-type]
        seen["keep_audio"] = cfg.keep_audio
        return 0

    monkeypatch.setattr(run_loop, "run_session", fake_run_session)
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    config = tmp_path / "config.toml"
    config.write_text("keep_audio = true\n")
    result = CliRunner().invoke(cli.app, ["run", "--config", str(config)])
    assert result.exit_code == 0, result.output
    assert seen["keep_audio"] is True


def test_unknown_file_keys_are_ignored_with_a_warning(tmp_path, capsys) -> None:
    """A key from another engine version (e.g. `diarize`) must not brick this one."""
    from huske.config import load_config

    config = tmp_path / "config.toml"
    config.write_text('diarize = true\nchunk_minutes = 5.0\nsome_future_key = "x"\n')
    cfg = load_config(config)
    assert cfg.chunk_minutes == 5.0
    err = capsys.readouterr().err
    assert "diarize" in err and "some_future_key" in err


def test_unknown_cli_override_still_fails() -> None:
    import pytest
    from pydantic import ValidationError

    from huske.config import load_config

    with pytest.raises(ValidationError):
        load_config(None, {"no_such_option": 1})


# --- transcription quality: language, dictionary, LLM post-processing -------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("pt", "pt"), ("PT", "pt"), ("pt-BR", "pt"), ("pt_BR", "pt"), ("portuguese", "pt"),
     ("auto", None), ("", None), (None, None)],
)
def test_language_is_normalized(raw: str | None, expected: str | None) -> None:
    assert RuntimeConfig(language=raw).language == expected


def test_unknown_language_is_rejected() -> None:
    with pytest.raises(ValueError, match="unknown language"):
        RuntimeConfig(language="klingon")


def test_vocabulary_defaults_empty_and_cleans_input() -> None:
    cfg = RuntimeConfig()
    assert cfg.vocabulary == []
    assert cfg.vocabulary_replacements == {}
    cleaned = RuntimeConfig(
        vocabulary=[" OKR ", "", "okr", "Kubernetes"],
        vocabulary_replacements={" cube ernetes ": "Kubernetes"},
    )
    assert cleaned.vocabulary == ["OKR", "Kubernetes"]
    assert cleaned.vocabulary_replacements == {"cube ernetes": "Kubernetes"}


@pytest.mark.parametrize(
    "bad",
    [["x" * 81], ["line\nbreak"], ["tab\there"]],
)
def test_vocabulary_rejects_unusable_entries(bad: list[str]) -> None:
    with pytest.raises(ValueError):
        RuntimeConfig(vocabulary=bad)


def test_vocabulary_replacement_needs_both_sides() -> None:
    with pytest.raises(ValueError):
        RuntimeConfig(vocabulary_replacements={"husky": ""})


def test_vocabulary_round_trips_through_toml(tmp_path: Path) -> None:
    cfg_file = tmp_path / "config.toml"
    update_user_config(
        {"vocabulary": ["OKR", "Huske"], "vocabulary_replacements": {"husky": "Huske"}},
        config_path=cfg_file,
    )
    cfg = load_config(config_path=cfg_file)
    assert cfg.vocabulary == ["OKR", "Huske"]
    assert cfg.vocabulary_replacements == {"husky": "Huske"}


@pytest.mark.parametrize(
    "backend", ["mlx", "ollama", "apple", "openai_compatible", "openai", "anthropic", "openrouter"]
)
def test_every_llm_backend_is_accepted(backend: str) -> None:
    assert RuntimeConfig(distill_backend=backend).distill_backend == backend  # type: ignore[arg-type]


def test_llm_post_processing_is_off_with_no_cloud_consent_by_default() -> None:
    cfg = RuntimeConfig()
    assert cfg.distill_enabled is False
    assert cfg.distill_cloud_consent is None
    assert cfg.distill_instructions == ""
    assert cfg.distill_context_tokens is None


@pytest.mark.parametrize(
    "endpoint",
    ["https://user:secret@api.example.com/v1", "ftp://example.com", "not a url", "http://"],
)
def test_distill_endpoint_rejects_unsafe_values(endpoint: str) -> None:
    with pytest.raises(ValueError):
        RuntimeConfig(distill_endpoint=endpoint)


def test_distill_endpoint_accepts_local_and_remote_urls() -> None:
    assert RuntimeConfig(distill_endpoint="http://127.0.0.1:1234/v1").distill_endpoint == (
        "http://127.0.0.1:1234/v1"
    )
    assert RuntimeConfig(distill_endpoint=" https://llm.example.com/v1/ ").distill_endpoint == (
        "https://llm.example.com/v1"
    )


def test_distill_cloud_consent_is_a_bare_host() -> None:
    assert RuntimeConfig(distill_cloud_consent="API.OpenAI.com").distill_cloud_consent == (
        "api.openai.com"
    )
    with pytest.raises(ValueError):
        RuntimeConfig(distill_cloud_consent="https://api.openai.com/v1")


def test_distill_instructions_are_bounded() -> None:
    assert RuntimeConfig(distill_instructions="  Remove filler words.  ").distill_instructions == (
        "Remove filler words."
    )
    with pytest.raises(ValueError):
        RuntimeConfig(distill_instructions="x" * 4001)
