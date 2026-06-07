"""The on-disk Statement sidecar — distillation's published contract.

A ``Statement`` is one self-contained factual claim distilled from a Passage,
carrying the Passage's time range + Source set as provenance (so retrieval can
ground it back in the transcript by time, independent of how the Passage index
happens to be windowed). A ``StatementSidecar`` is the whole ``.statements.json``
file: provenance for the source transcript plus the ordered Statements.

Kept dependency-free (stdlib only) — both the base-install distiller and the
``huske[mcp]`` embedder read/write this same shape.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any

SIDECAR_VERSION = 1


@dataclass(slots=True)
class Statement:
    """One distilled claim + its provenance (the source Passage's window)."""

    text: str
    start: datetime
    end: datetime
    sources: list[str]  # subset of ["mic", "system"] — the source Passage's set

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "start": self.start.isoformat(),
            "end": self.end.isoformat(),
            "sources": list(self.sources),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Statement:
        return cls(
            text=str(data["text"]),
            start=datetime.fromisoformat(str(data["start"])),
            end=datetime.fromisoformat(str(data["end"])),
            sources=[str(s) for s in (data.get("sources") or [])],
        )


@dataclass(slots=True)
class StatementSidecar:
    """The ``<name>.statements.json`` file written next to a transcript."""

    transcript_path: str  # resolved absolute path of the source ``.md``
    session_id: str
    source_sha256: str  # sha256 of the source ``.md`` bytes — for incremental skip
    model: str  # the distill model id used (e.g. "gemma4:e2b")
    backend: str  # the distill backend (e.g. "ollama")
    distilled_at: str  # ISO-8601 timestamp the sidecar was produced
    statements: list[Statement]
    version: int = SIDECAR_VERSION

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "transcript_path": self.transcript_path,
            "session_id": self.session_id,
            "source_sha256": self.source_sha256,
            "model": self.model,
            "backend": self.backend,
            "distilled_at": self.distilled_at,
            "statements": [s.to_dict() for s in self.statements],
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> StatementSidecar:
        raw = data.get("statements") or []
        return cls(
            version=int(data.get("version", SIDECAR_VERSION)),
            transcript_path=str(data["transcript_path"]),
            session_id=str(data["session_id"]),
            source_sha256=str(data["source_sha256"]),
            model=str(data.get("model", "")),
            backend=str(data.get("backend", "")),
            distilled_at=str(data.get("distilled_at", "")),
            statements=[Statement.from_dict(s) for s in raw],
        )
