"""Parse on-disk transcripts (``.md`` + YAML frontmatter) into ``TranscriptDoc``.

This consumes the published transcript contract
(``specs/001-huske-recorder/contracts/transcript-format.md``) rather than the
in-memory ``Transcript`` object, so the live indexing path and the
``huske index`` backfill share exactly one code path (see
docs/adr/0003-embed-worker-isolation.md). The cost is run-start timestamp
granularity (we only have the ``[HH:MM:SS · source]`` prefix per run), which is
sufficient for citations.
"""

from __future__ import annotations

import re
from datetime import datetime, time, timedelta
from pathlib import Path

import yaml

from huske.search.models import Run, TranscriptDoc

_FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?(.*)\Z", re.DOTALL)
# ``[HH:MM:SS · source] text`` — the separator is U+00B7 surrounded by spaces.
_RUN_RE = re.compile(
    r"^\[(?P<ts>\d{1,2}:\d{2}:\d{2})\s*·\s*(?P<src>[^\]]+)\]\s*(?P<text>.*)\Z",
    re.DOTALL,
)
_SOURCE_NORMALIZE = {"mic": "mic", "microphone": "mic", "system": "system"}


class ParseError(ValueError):
    """Raised when a file is not a parseable huske transcript."""


def _normalize_source(label: str) -> str:
    return _SOURCE_NORMALIZE.get(label.strip().lower(), label.strip())


def _run_datetime(base: datetime, hms: time) -> datetime:
    """Combine a wall-clock ``HH:MM:SS`` with the transcript's date/tz.

    Handles a chunk that crosses midnight: if the run time lands before the
    chunk start by more than an hour, it belongs to the next day.
    """
    dt = datetime.combine(base.date(), hms, tzinfo=base.tzinfo)
    if dt < base - timedelta(hours=1):
        dt += timedelta(days=1)
    return dt


def parse_transcript(path: Path) -> TranscriptDoc:
    """Parse ``path`` into a ``TranscriptDoc``. Raises ``ParseError`` on bad input."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:  # pragma: no cover - I/O edge
        raise ParseError(f"cannot read {path}: {exc}") from exc

    m = _FRONTMATTER_RE.match(raw)
    if not m:
        raise ParseError(f"{path}: missing YAML frontmatter")
    try:
        front = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as exc:
        raise ParseError(f"{path}: invalid frontmatter: {exc}") from exc
    if not isinstance(front, dict):
        raise ParseError(f"{path}: frontmatter is not a mapping")

    try:
        start_time = _parse_dt(front["start_time"])
        end_time = _parse_dt(front["end_time"])
        session_id = str(front["session_id"])
        chunk_seq = int(front["chunk_seq"])
    except (KeyError, ValueError, TypeError) as exc:
        raise ParseError(f"{path}: bad frontmatter field: {exc}") from exc
    language = str(front.get("language", "auto"))

    runs = _parse_body(m.group(2), start_time)
    return TranscriptDoc(
        path=path,
        session_id=session_id,
        chunk_seq=chunk_seq,
        start_time=start_time,
        end_time=end_time,
        language=language,
        runs=runs,
    )


def _parse_dt(value: object) -> datetime:
    if isinstance(value, datetime):
        dt = value
    else:
        dt = datetime.fromisoformat(str(value))
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt


def _parse_body(body: str, start_time: datetime) -> list[Run]:
    runs: list[Run] = []
    for para in re.split(r"\n\s*\n", body.strip()):
        para = para.strip()
        if not para or para.startswith("#") or para.startswith("_("):
            continue
        rm = _RUN_RE.match(para)
        if not rm:
            continue
        text = " ".join(rm.group("text").split())
        if not text:
            continue
        try:
            hms = datetime.strptime(rm.group("ts"), "%H:%M:%S").time()
        except ValueError:
            continue
        runs.append(
            Run(
                start=_run_datetime(start_time, hms),
                source=_normalize_source(rm.group("src")),
                text=text,
            )
        )
    return runs
