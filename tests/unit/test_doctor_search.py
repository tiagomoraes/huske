"""doctor search-subsystem checks."""

from __future__ import annotations

from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from huske.config import RuntimeConfig
from huske.doctor import _search_checks


def _checks(cfg: RuntimeConfig) -> dict[str, object]:
    return {c.name: c for c in _search_checks(cfg)}


def test_store_check_ok_when_sqlite_vec_present(tmp_path: Path) -> None:
    cfg = RuntimeConfig(index_root=tmp_path / "index", output_root=tmp_path / "t")
    checks = _checks(cfg)
    assert checks["search store"].ok is True
    assert "sqlite-vec" in checks["search store"].detail
    # No index yet → informational, not a failure.
    assert checks["search index"].ok is True
    assert "no index yet" in checks["search index"].detail


def test_missing_embeddings_optional_unless_enabled(tmp_path: Path) -> None:
    pytest.importorskip  # noqa: B018
    try:
        import mlx_embeddings  # type: ignore[import-not-found]  # noqa: F401
    except ImportError:
        pass
    else:
        pytest.skip("mlx-embeddings installed; can't test the missing-dep branch")

    disabled = RuntimeConfig(index_root=tmp_path / "i", output_root=tmp_path / "t")
    assert _checks(disabled)["embeddings"].ok is True  # optional when not opted in

    enabled = RuntimeConfig(
        index_root=tmp_path / "i", output_root=tmp_path / "t", indexing_enabled=True
    )
    assert _checks(enabled)["embeddings"].ok is False  # opted in but missing → failure
