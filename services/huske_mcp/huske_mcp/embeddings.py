"""Optional semantic backend; never imported by the default tiny profile."""

from __future__ import annotations

from typing import Any


class EmbeddingUnavailable(RuntimeError):
    pass


class Model2VecEmbedder:
    """Lazy, CPU-only static embeddings for the semantic profile."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model: Any = None
        self._numpy: Any = None

    def _load(self) -> None:
        if self._model is not None:
            return
        try:
            import numpy
            from model2vec import StaticModel
        except ImportError as exc:
            raise EmbeddingUnavailable(
                "semantic profile needs `pip install 'huske-mcp[semantic]'`"
            ) from exc
        self._numpy = numpy
        self._model = StaticModel.from_pretrained(self.model_id)

    def encode(self, texts: list[str]) -> list[bytes]:
        self._load()
        matrix = self._model.encode(texts)
        matrix = self._normalize(matrix)
        return [row.astype("<f4", copy=False).tobytes() for row in matrix]

    def encode_query(self, text: str) -> Any:
        self._load()
        matrix = self._model.encode([text])
        return self._normalize(matrix)[0].astype("<f4", copy=False)

    def similarity(self, query: Any, vectors: list[bytes]) -> list[float]:
        self._load()
        if not vectors:
            return []
        matrix = self._numpy.stack(
            [self._numpy.frombuffer(value, dtype="<f4") for value in vectors]
        )
        return [float(value) for value in matrix @ query]

    def _normalize(self, matrix: Any) -> Any:
        norms = self._numpy.linalg.norm(matrix, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        return matrix / norms
