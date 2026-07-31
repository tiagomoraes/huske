from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import ValidationError

from huske.config import RuntimeConfig


def test_sync_defaults_are_inert() -> None:
    cfg = RuntimeConfig()
    assert cfg.sync_enabled is False
    assert cfg.sync_provider == "git"
    assert cfg.sync_remote is None
    assert cfg.sync_branch == "main"
    assert cfg.sync_root == Path.home() / "huske" / "sync"


def test_enabled_sync_requires_remote() -> None:
    with pytest.raises(ValidationError, match="requires sync_remote"):
        RuntimeConfig(sync_enabled=True)


def test_sync_remote_rejects_git_option_injection() -> None:
    with pytest.raises(ValidationError, match="safe Git repository"):
        RuntimeConfig(sync_remote="--upload-pack=malicious")


@pytest.mark.parametrize(
    "branch",
    ("../main", "feature//name", "feature/.hidden", "feature/name.lock", "@"),
)
def test_sync_branch_rejects_unsafe_values(branch: str) -> None:
    with pytest.raises(ValidationError, match="safe Git branch"):
        RuntimeConfig(sync_branch=branch)
