"""Tests for huske.config."""

from __future__ import annotations

import platform
from pathlib import Path

import pytest

from huske.config import RuntimeConfig, load_config


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
