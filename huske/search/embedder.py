"""Text embedders behind a small protocol.

``MlxE5Embedder`` is the production embedder: it rides the MLX/Metal runtime
``mlx-whisper`` already ships (see docs/adr/0002-local-search-stack.md) and runs
``multilingual-e5`` with the model's required ``passage:`` / ``query:`` prefixes.

``HashingEmbedder`` is a deterministic, dependency-free stand-in used by the
test suite and CI (which need not install the ``huske[mcp]`` extra), mirroring
huske's "test the pipeline without whisper" approach. It is never selected for
real workloads unless explicitly requested by model id.
"""

from __future__ import annotations

import hashlib
import math
import re
from typing import Protocol, runtime_checkable

_TOKEN_RE = re.compile(r"\w+", re.UNICODE)


class EmbedderUnavailable(RuntimeError):
    """The requested embedding backend (e.g. mlx-embeddings) is not installed."""


@runtime_checkable
class Embedder(Protocol):
    """Embeds passages and queries into a shared vector space."""

    model_id: str
    dim: int

    def embed_passages(self, texts: list[str]) -> list[list[float]]: ...

    def embed_query(self, text: str) -> list[float]: ...

    def count_tokens(self, text: str) -> int: ...


def _l2_normalize(vec: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vec)) or 1.0
    return [x / norm for x in vec]


class HashingEmbedder:
    """Deterministic bag-of-words hashing embedder. No ML dependencies.

    Identical text yields an identical vector and shared tokens yield partial
    similarity, which is enough for tests asserting "the exact passage ranks
    first". It is NOT a real semantic model — prefixes are intentionally ignored
    so query/passage of the same text match exactly.
    """

    def __init__(self, model_id: str = "hashing", dim: int = 768) -> None:
        self.model_id = model_id
        self.dim = dim

    def _vec(self, text: str) -> list[float]:
        v = [0.0] * self.dim
        for tok in _TOKEN_RE.findall(text.lower()):
            h = int.from_bytes(hashlib.blake2b(tok.encode("utf-8"), digest_size=8).digest(), "big")
            sign = 1.0 if (h >> 16) & 1 else -1.0
            v[h % self.dim] += sign
        return _l2_normalize(v)

    def embed_passages(self, texts: list[str]) -> list[list[float]]:
        return [self._vec(t) for t in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._vec(text)

    def count_tokens(self, text: str) -> int:
        return max(1, round(len(text.split()) * 1.5))


class FastEmbedE5Embedder:
    """multilingual-e5 via ``fastembed`` (onnxruntime, CPU).

    The non-Metal backend for the off-device huske server (a Linux VPS cannot
    run the MLX/Metal path). Named in docs/adr/0002-local-search-stack.md as the
    documented fallback and made load-bearing for the server in
    docs/adr/0004-off-device-huske-server.md. Selected by a ``fastembed:<hf-id>``
    model id, e.g. ``fastembed:intfloat/multilingual-e5-large``.

    Like the MLX embedder, e5 is asymmetric: passages are prefixed ``passage: ``
    and queries ``query: ``, and outputs are L2-normalized so the two backends
    share the same cosine geometry over the *same* weights. A given index is
    still embedded entirely by one backend (the server owns its own vector
    space); the model id recorded in the store guards against mixing.
    """

    def __init__(self, model_id: str, *, batch_size: int = 16) -> None:
        try:
            from fastembed import TextEmbedding
        except ImportError as exc:  # pragma: no cover - exercised on the server
            raise EmbedderUnavailable(
                "fastembed is not installed. Install the server extra:\n"
                "  pip install 'huske[server]'"
            ) from exc

        self.model_id = model_id
        self.batch_size = batch_size
        hf_id = model_id.split(":", 1)[1] if ":" in model_id else model_id
        self._hf_id = hf_id
        self._model = TextEmbedding(model_name=hf_id)
        self.dim = len(self._encode(["passage: probe"])[0])

    def _encode(self, texts: list[str]) -> list[list[float]]:  # pragma: no cover - on-server
        out: list[list[float]] = []
        for vec in self._model.embed(texts, batch_size=self.batch_size):
            out.append(_l2_normalize([float(x) for x in vec]))
        return out

    def embed_passages(self, texts: list[str]) -> list[list[float]]:  # pragma: no cover
        return self._encode([f"passage: {t}" for t in texts])

    def embed_query(self, text: str) -> list[float]:  # pragma: no cover
        return self._encode([f"query: {text}"])[0]

    def count_tokens(self, text: str) -> int:  # pragma: no cover - on-server
        # fastembed does not expose a stable public tokenizer; approximate
        # conservatively so windows stay under e5's 512-token limit. Slightly
        # over-counting only makes Passages a touch smaller, which is safe.
        return max(1, round(len(_TOKEN_RE.findall(text)) * 1.3))


class MlxE5Embedder:
    """multilingual-e5 via mlx-embeddings (Apple Silicon / Metal).

    Requires the ``huske[mcp]`` extra. e5 is asymmetric: passages must be
    prefixed ``passage: `` and queries ``query: ``.
    """

    def __init__(self, model_id: str, *, batch_size: int = 16) -> None:
        try:
            from mlx_embeddings.utils import load
        except ImportError as exc:  # pragma: no cover - exercised on-device
            raise EmbedderUnavailable(
                "mlx-embeddings is not installed. Install the search extra:\n"
                "  pip install 'huske[mcp]'"
            ) from exc

        self.model_id = model_id
        self.batch_size = batch_size
        self._model, self._tokenizer = load(model_id)
        # Probe the output dimension once.
        self.dim = len(self._encode(["passage: probe"])[0])

    def _encode(self, texts: list[str]) -> list[list[float]]:  # pragma: no cover - on-device
        import mlx.core as mx

        out: list[list[float]] = []
        for i in range(0, len(texts), self.batch_size):
            batch = texts[i : i + self.batch_size]
            enc = self._tokenizer.batch_encode_plus(
                batch,
                return_tensors="mlx",
                padding=True,
                truncation=True,
                max_length=512,
            )
            result = self._model(enc["input_ids"], attention_mask=enc["attention_mask"])
            # mlx-embeddings exposes pooled, normalized sentence embeddings as
            # ``text_embeds``; fall back to mean-pooling last_hidden_state.
            embeds = getattr(result, "text_embeds", None)
            if embeds is None:
                hidden = result.last_hidden_state
                mask = enc["attention_mask"][..., None]
                summed = (hidden * mask).sum(axis=1)
                counts = mx.maximum(mask.sum(axis=1), 1)
                embeds = summed / counts
            mx.eval(embeds)
            for row in embeds.tolist():
                out.append(_l2_normalize([float(x) for x in row]))
        return out

    def embed_passages(self, texts: list[str]) -> list[list[float]]:  # pragma: no cover
        return self._encode([f"passage: {t}" for t in texts])

    def embed_query(self, text: str) -> list[float]:  # pragma: no cover
        return self._encode([f"query: {text}"])[0]

    def count_tokens(self, text: str) -> int:  # pragma: no cover - on-device
        return len(self._tokenizer.encode(text))


def embedder_backend(model_id: str) -> str:
    """Map a model id to its backend: ``hashing`` | ``fastembed`` | ``mlx``.

    Pure routing logic, separated so it is testable without loading any model.
    """
    if model_id in ("hashing", "fake") or model_id.startswith("hashing:"):
        return "hashing"
    if model_id.startswith("fastembed:"):
        return "fastembed"
    return "mlx"


def build_embedder(model_id: str) -> Embedder:
    """Construct the embedder for ``model_id``.

    - ``hashing`` / ``hashing:<dim>`` / ``fake`` → dependency-free test embedder.
    - ``fastembed:<hf-id>`` → CPU onnxruntime e5 (the off-device server).
    - anything else → MLX/Metal e5 (the local Mac).
    """
    backend = embedder_backend(model_id)
    if backend == "hashing":
        if model_id.startswith("hashing:"):
            return HashingEmbedder(model_id=model_id, dim=int(model_id.split(":", 1)[1]))
        return HashingEmbedder(model_id=model_id)
    if backend == "fastembed":
        return FastEmbedE5Embedder(model_id)
    return MlxE5Embedder(model_id)
