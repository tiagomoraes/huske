"""Config + path defaults for the local-search / MCP subsystem."""

from __future__ import annotations

from pathlib import Path

from huske import paths
from huske.config import RuntimeConfig


def test_search_config_defaults() -> None:
    cfg = RuntimeConfig()
    assert cfg.indexing_enabled is False
    assert cfg.embedding_model == "mlx-community/multilingual-e5-base"
    assert cfg.mcp_host == "127.0.0.1"
    assert cfg.mcp_port == 7641
    assert cfg.index_root == Path.home() / "huske" / "index"


def test_index_root_expands_user(tmp_path: Path) -> None:
    cfg = RuntimeConfig(index_root=tmp_path / "idx")
    assert paths.index_root(cfg) == tmp_path / "idx"
    assert paths.index_db_path(cfg) == tmp_path / "idx" / "passages.db"


def test_mcp_port_bounds() -> None:
    import pytest
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        RuntimeConfig(mcp_port=0)
    with pytest.raises(ValidationError):
        RuntimeConfig(mcp_port=99999)


def test_indexing_toggle_via_toml(tmp_path: Path) -> None:
    from huske.config import load_config

    cfg_file = tmp_path / "config.toml"
    cfg_file.write_text("indexing_enabled = true\nmcp_port = 8000\n", encoding="utf-8")
    cfg = load_config(config_path=cfg_file)
    assert cfg.indexing_enabled is True
    assert cfg.mcp_port == 8000
