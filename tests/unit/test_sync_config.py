"""Config surface for off-device replication (ADR 0004)."""

from __future__ import annotations

from pathlib import Path

from huske.config import RuntimeConfig, load_config


def test_replication_defaults_are_inert() -> None:
    cfg = RuntimeConfig()
    # The send side is off until an endpoint is configured.
    assert cfg.sync_endpoint is None
    assert cfg.sync_verify_tls is True
    assert cfg.sync_root == Path.home() / "huske" / "sync"
    # Serve-side defaults are loopback.
    assert cfg.ingest_host == "127.0.0.1"
    assert cfg.ingest_port == 7642
    assert cfg.public_host is None


def test_sync_endpoint_and_serve_overrides() -> None:
    cfg = load_config(
        cli_overrides={
            "sync_endpoint": "https://huske.example.com",
            "ingest_port": 9000,
            "public_host": "huske.example.com",
            "embedding_model": "fastembed:intfloat/multilingual-e5-large",
        }
    )
    assert cfg.sync_endpoint == "https://huske.example.com"
    assert cfg.ingest_port == 9000
    assert cfg.public_host == "huske.example.com"
    assert cfg.embedding_model == "fastembed:intfloat/multilingual-e5-large"


def test_sync_root_expands_user(tmp_path: Path) -> None:
    cfg = load_config(cli_overrides={"sync_root": "~/somewhere/sync"})
    assert cfg.sync_root.is_absolute()
    assert "~" not in str(cfg.sync_root)
