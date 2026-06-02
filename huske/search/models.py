"""Dataclasses for the search subsystem.

``Run`` and ``TranscriptDoc`` model what we parse out of an on-disk ``.md``
transcript (the published contract). ``Passage`` is the retrieval unit we embed
and store. ``SearchHit`` is what a query returns. See CONTEXT.md for the domain
terms.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


@dataclass(slots=True)
class Run:
    """One ``[HH:MM:SS · source]`` paragraph from a transcript body."""

    start: datetime
    source: str  # "mic" | "system" | "" (unknown)
    text: str


@dataclass(slots=True)
class TranscriptDoc:
    """A parsed transcript: the frontmatter we need + ordered runs."""

    path: Path
    session_id: str
    chunk_seq: int
    start_time: datetime
    end_time: datetime
    language: str
    runs: list[Run]

    @property
    def date(self) -> str:
        return self.start_time.date().isoformat()


@dataclass(slots=True)
class Passage:
    """A retrieval-sized window. One Passage → one embedding vector."""

    uid: str
    text: str
    start: datetime
    end: datetime
    sources: list[str]  # first-seen order, subset of ["mic", "system"]
    session_id: str
    day: int  # YYYYMMDD (local date of ``start``)
    path: str  # absolute transcript path
    title: str

    @property
    def has_mic(self) -> bool:
        return "mic" in self.sources

    @property
    def has_system(self) -> bool:
        return "system" in self.sources


@dataclass(slots=True)
class SearchHit:
    """A single search result, carrying citation metadata."""

    uid: str
    title: str
    url: str
    text: str
    score: float  # cosine similarity in [0, 1] (1 == identical)
    session_id: str
    day: int
    start_ms: int
    end_ms: int
    sources: list[str]
    path: str
