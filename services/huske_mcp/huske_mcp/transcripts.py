"""Independent reader for Huske's published Markdown transcript contract."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from pathlib import Path

_FRONTMATTER = re.compile(r"^---\n(?P<front>.*?)\n---\n?(?P<body>.*)\Z", re.DOTALL)
_RUN = re.compile(
    r"^\[(?P<clock>\d{1,2}:\d{2}:\d{2})\s*·\s*(?P<source>[^\]]+)\]\s*(?P<text>.*)\Z",
    re.DOTALL,
)
_DATE_DIR = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_SOURCE = {"microphone": "mic", "mic": "mic", "system": "system"}
_MAX_TRANSCRIPT_BYTES = 8 * 1024 * 1024


class TranscriptError(ValueError):
    pass


@dataclass(frozen=True)
class Run:
    start: datetime
    source: str
    text: str


@dataclass(frozen=True)
class Passage:
    ordinal: int
    title: str
    text: str
    start: datetime
    end: datetime
    sources: str


@dataclass(frozen=True)
class Transcript:
    relative_path: str
    session_id: str
    start: datetime
    end: datetime
    language: str
    runs: tuple[Run, ...]


def iter_transcript_paths(root: Path) -> list[Path]:
    if not root.exists():
        return []
    if root.is_symlink():
        raise TranscriptError("transcript root must not be a symlink")
    paths: list[Path] = []
    for day in root.iterdir():
        if not day.is_dir() or day.is_symlink() or not _DATE_DIR.fullmatch(day.name):
            continue
        for path in day.glob("*.md"):
            if (
                path.is_file()
                and not path.is_symlink()
                and path.name.lower() != "readme.md"
            ):
                paths.append(path)
    return sorted(paths)


def parse_transcript(path: Path, root: Path) -> Transcript:
    try:
        if path.stat().st_size > _MAX_TRANSCRIPT_BYTES:
            raise TranscriptError(f"{path}: transcript exceeds 8 MiB safety limit")
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise TranscriptError(f"cannot read {path}: {exc}") from exc
    match = _FRONTMATTER.match(raw)
    if match is None:
        raise TranscriptError(f"{path}: missing YAML frontmatter")
    front = _simple_frontmatter(match["front"])
    try:
        start = _datetime(front["start_time"])
        end = _datetime(front["end_time"])
        session_id = front["session_id"]
    except (KeyError, ValueError) as exc:
        raise TranscriptError(f"{path}: invalid required frontmatter: {exc}") from exc
    runs = tuple(_parse_runs(match["body"], start))
    try:
        rel = path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as exc:
        raise TranscriptError(f"{path}: outside transcript root") from exc
    return Transcript(
        relative_path=rel,
        session_id=session_id,
        start=start,
        end=end,
        language=front.get("language", "auto"),
        runs=runs,
    )


def window_transcript(
    transcript: Transcript,
    *,
    target_words: int = 220,
    max_gap_seconds: float = 120.0,
) -> list[Passage]:
    """Group consecutive runs into bounded, timestamped retrieval passages."""
    passages: list[Passage] = []
    current: list[Run] = []
    words = 0

    def emit(end_hint: datetime | None = None) -> None:
        nonlocal current, words
        if not current:
            return
        sources = ",".join(dict.fromkeys(run.source for run in current))
        start = current[0].start
        end = end_hint or transcript.end
        title = (
            f"{start.date().isoformat()} {start:%H:%M}-{end:%H:%M} · "
            f"{sources or 'speech'}"
        )
        passages.append(
            Passage(
                ordinal=len(passages),
                title=title,
                text=" ".join(run.text for run in current),
                start=start,
                end=end,
                sources=sources,
            )
        )
        current = []
        words = 0

    for run in transcript.runs:
        count = len(run.text.split())
        if current:
            gap = (run.start - current[-1].start).total_seconds()
            if words + count > target_words or gap > max_gap_seconds:
                emit(run.start)
        current.append(run)
        words += count
    emit()
    return passages


def _simple_frontmatter(text: str) -> dict[str, str]:
    """Parse the scalar fields the stable contract requires, without PyYAML."""
    result: dict[str, str] = {}
    for line in text.splitlines():
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        cleaned = value.strip().strip("'\"")
        if cleaned:
            result[key.strip()] = cleaned
    return result


def _datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError("timestamp has no UTC offset")
    return parsed


def _parse_runs(body: str, start: datetime) -> list[Run]:
    runs: list[Run] = []
    for paragraph in re.split(r"\n\s*\n", body.strip()):
        match = _RUN.match(paragraph.strip())
        if match is None:
            continue
        text = " ".join(match["text"].split())
        if not text:
            continue
        try:
            clock = datetime.strptime(match["clock"], "%H:%M:%S").time()
        except ValueError:
            continue
        runs.append(
            Run(
                start=_run_datetime(start, clock),
                source=_SOURCE.get(match["source"].strip().lower(), match["source"].strip()),
                text=text,
            )
        )
    return runs


def _run_datetime(start: datetime, clock: time) -> datetime:
    value = datetime.combine(start.date(), clock, tzinfo=start.tzinfo)
    if value < start - timedelta(hours=1):
        value += timedelta(days=1)
    return value
