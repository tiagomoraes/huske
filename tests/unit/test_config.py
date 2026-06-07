"""Tests for huske.config."""

from __future__ import annotations

import platform
from pathlib import Path

import pytest

from huske.config import RuntimeConfig, load_config, update_user_config


def test_defaults_are_sane() -> None:
    cfg = RuntimeConfig()
    assert cfg.chunk_minutes == 15.0
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
    assert cfg.distill_backend == "ollama"
    # Lightest portable tier — runs across the whole Apple-Silicon range.
    assert cfg.distill_model == "qwen3.5:0.8b"
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
