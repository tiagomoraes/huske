"""build_embedder backend routing (no model loads for the pure cases)."""

from __future__ import annotations

import pytest

from huske.search.embedder import (
    EmbedderUnavailable,
    HashingEmbedder,
    build_embedder,
    embedder_backend,
)


def test_backend_routing() -> None:
    assert embedder_backend("hashing") == "hashing"
    assert embedder_backend("fake") == "hashing"
    assert embedder_backend("hashing:128") == "hashing"
    assert embedder_backend("fastembed:intfloat/multilingual-e5-large") == "fastembed"
    assert embedder_backend("mlx-community/multilingual-e5-base") == "mlx"


def test_build_hashing_variants() -> None:
    assert isinstance(build_embedder("hashing"), HashingEmbedder)
    assert isinstance(build_embedder("fake"), HashingEmbedder)
    assert build_embedder("hashing:128").dim == 128


def test_build_embedder_accepts_tuning_kwargs() -> None:
    # The dependency-free backend ignores the batch/memory knobs but must accept
    # them so callers (`huske index`, the embed worker) can pass tuning uniformly.
    emb = build_embedder("hashing", batch_size=4, cache_limit_mb=64, memory_limit_mb=128)
    assert isinstance(emb, HashingEmbedder)
    # Every backend exposes a release() hook the backfill can call between files.
    assert callable(getattr(emb, "release", None))
    emb.release()  # no-op on the hashing backend; must not raise


def test_fastembed_routing_when_missing_raises_unavailable() -> None:
    try:
        import fastembed  # noqa: F401
    except ImportError:
        with pytest.raises(EmbedderUnavailable):
            build_embedder("fastembed:intfloat/multilingual-e5-large")
    else:  # pragma: no cover - only when the server extra is installed
        pytest.skip("fastembed installed; routing covered by test_backend_routing")
