"""``huske export``: one Markdown file per day, for tools that will never speak MCP.

The MCP connector is the good path — semantic search, statement grounding,
time-scoped recall, and custody of the data staying with you. But it is not the
*only* place transcripts are useful, and some destinations have no MCP at all:
a Claude Project, NotebookLM, an Obsidian vault, a shared folder, a Drive that a
phone already reads.

Those destinations all want the same shape, and it is not huske's native one.
huske writes many small files per day (one per Chunk); a folder-reading tool has
to guess which of thousands is relevant, with no date filter and no ranking. So
export inverts it: **one file per day**, statements first, full text below, so a
single document answers "what happened on the 27th" by being opened.

What this deliberately does *not* do is replace the index. Keyword search over
concatenated speech is a real downgrade from embedding search over Passages, and
a synced folder puts plaintext wherever the sync provider keeps it — see the
privacy note in docs/integrations.md before pointing this at someone else's
cloud.

Stdlib + PyYAML (already a base dependency, via the transcript parser). No
search extra, no network.
"""

from __future__ import annotations

import hashlib
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from huske.config import RuntimeConfig
    from huske.search.models import TranscriptDoc

# Bumped when the rendered layout changes in a way that should force a rewrite of
# already-exported days.
EXPORT_FORMAT_VERSION = 1

_STAMP = "source_digest"


@dataclass(slots=True)
class DayExport:
    """One rendered day file, ready to write."""

    date: str
    path: Path
    markdown: str
    source_digest: str
    transcripts: int
    statements: int


@dataclass(slots=True)
class ExportResult:
    written: list[str]
    skipped: list[str]
    failed: list[tuple[str, str]]

    @property
    def total(self) -> int:
        return len(self.written) + len(self.skipped)


def _day_digest(paths: list[Path]) -> str:
    """A stable fingerprint of a day's inputs, so re-export is a no-op.

    Covers the sidecars as well as the transcripts: turning distillation on
    changes a day's export without changing a single transcript byte.
    """
    h = hashlib.sha256()
    h.update(f"v{EXPORT_FORMAT_VERSION}\n".encode())
    for path in sorted(paths):
        h.update(path.name.encode("utf-8"))
        try:
            h.update(hashlib.sha256(path.read_bytes()).digest())
        except OSError:  # pragma: no cover - vanished mid-run
            continue
        sidecar = _sidecar_path(path)
        if sidecar.exists():
            try:
                h.update(hashlib.sha256(sidecar.read_bytes()).digest())
            except OSError:  # pragma: no cover
                pass
    return h.hexdigest()[:16]


def _sidecar_path(transcript: Path) -> Path:
    from huske.paths import statements_sidecar_path

    return statements_sidecar_path(transcript)


def existing_digest(path: Path) -> str | None:
    """Read the ``source_digest`` stamp from a previously exported file.

    The stamp lives in the frontmatter, so only the head of the file is read —
    re-exporting a year of days must not mean re-reading a year of text.
    """
    try:
        with path.open("r", encoding="utf-8") as f:
            head = f.read(2048)
    except OSError:  # includes FileNotFoundError on a first export
        return None
    for line in head.splitlines():
        if line.startswith(f"{_STAMP}:"):
            return line.split(":", 1)[1].strip().strip('"')
        if line.startswith("# "):  # past the frontmatter
            break
    return None


def group_by_day(output_root: Path) -> dict[str, list[Path]]:
    """Transcript paths grouped by their ``YYYY-MM-DD`` day folder."""
    from huske.search.indexer import iter_transcripts

    days: dict[str, list[Path]] = defaultdict(list)
    for path in iter_transcripts(output_root):
        days[path.parent.name].append(path)
    return {day: sorted(paths) for day, paths in sorted(days.items())}


def _clock(dt: datetime) -> str:
    return dt.strftime("%H:%M")


def _speaker(source: str) -> str:
    # The transcript has no diarization; source is the only speaker-like axis, so
    # name it in the terms a reader (or a model) can act on.
    return {"mic": "me", "system": "other"}.get(source, source or "?")


def render_day(
    day: str,
    paths: list[Path],
    *,
    statements_only: bool = False,
    digest: str | None = None,
) -> DayExport:
    """Render one day's transcripts into a single Markdown document.

    ``digest`` lets a caller that already computed the day's fingerprint (to
    decide whether to render at all) pass it in — otherwise a full export
    re-hashes every transcript on disk twice.
    """
    from huske.distill.sidecar import read_sidecar
    from huske.search.parser import ParseError, parse_transcript

    docs: list[TranscriptDoc] = []
    for path in paths:
        try:
            docs.append(parse_transcript(path))
        except ParseError:
            continue  # a half-written or foreign .md must not sink the day
    docs.sort(key=lambda d: (d.start_time, d.chunk_seq))

    statements: list[tuple[datetime, str, list[str]]] = []
    for path in paths:
        sidecar = read_sidecar(path)
        if sidecar is None:
            continue
        statements.extend((s.start, s.text, s.sources) for s in sidecar.statements)
    statements.sort(key=lambda s: s[0])

    sessions: dict[str, list[TranscriptDoc]] = defaultdict(list)
    for doc in docs:
        sessions[doc.session_id].append(doc)

    body: list[str] = []
    first = docs[0].start_time if docs else None
    last = docs[-1].end_time if docs else None

    stamp = digest if digest is not None else _day_digest(paths)
    front = [
        "---",
        f"date: {day}",
        f"sessions: {len(sessions)}",
        f"transcripts: {len(docs)}",
        f"statements: {len(statements)}",
    ]
    if first and last:
        front.append(f"span: {_clock(first)}–{_clock(last)}")  # noqa: RUF001
    front += [
        f"generator: huske export (format v{EXPORT_FORMAT_VERSION})",
        f"{_STAMP}: {stamp}",
        "---",
        "",
        "",  # blank line after the fence, as in huske's own transcripts
    ]

    body.append(f"# {day}")
    body.append("")
    if not docs:
        body.append("_No transcripts for this day._")
    else:
        summary = f"{len(sessions)} session(s), {len(docs)} transcript(s)"
        if first and last:
            summary += f", {_clock(first)}–{_clock(last)}"  # noqa: RUF001
        body.append(f"_{summary}. `me` = microphone, `other` = system audio._")
        body.append("")

    if statements:
        body.append("## Key points")
        body.append("")
        for start, text, _sources in statements:
            body.append(f"- **{_clock(start)}** — {text}")
        body.append("")

    if not statements_only and docs:
        body.append("## Conversations")
        body.append("")
        for session_id, session_docs in sorted(
            sessions.items(), key=lambda kv: kv[1][0].start_time
        ):
            began = _clock(session_docs[0].start_time)
            ended = _clock(session_docs[-1].end_time)
            body.append(f"### {began}–{ended} · session `{session_id}`")  # noqa: RUF001
            body.append("")
            for doc in session_docs:
                for run in doc.runs:
                    body.append(f"**{_clock(run.start)} {_speaker(run.source)}:** {run.text}")
                    body.append("")

    markdown = "\n".join(front) + "\n".join(body).rstrip() + "\n"
    return DayExport(
        date=day,
        path=Path(f"{day}.md"),
        markdown=markdown,
        source_digest=stamp,
        transcripts=len(docs),
        statements=len(statements),
    )


def export_days(
    output_root: Path,
    export_root: Path,
    *,
    statements_only: bool = False,
    force: bool = False,
    since: str | None = None,
    on_progress: object = None,
) -> ExportResult:
    """Write one Markdown file per day into ``export_root``. Incremental."""
    result = ExportResult(written=[], skipped=[], failed=[])
    export_root.mkdir(parents=True, exist_ok=True)

    for day, paths in group_by_day(output_root).items():
        if since and day < since:
            continue
        target = export_root / f"{day}.md"
        try:
            digest = _day_digest(paths)
            if not force and existing_digest(target) == digest:
                result.skipped.append(day)
                continue
            rendered = render_day(
                day, paths, statements_only=statements_only, digest=digest
            )
            # Atomic replace so a synced folder never uploads a half-written file.
            tmp = target.with_name(f".{target.name}.tmp")
            tmp.write_text(rendered.markdown, encoding="utf-8")
            tmp.replace(target)
            result.written.append(day)
            if callable(on_progress):
                on_progress(rendered)
        except OSError as exc:
            result.failed.append((day, str(exc)))
    return result


def run_export(
    config_path: Path | None = None,
    cli_overrides: dict[str, object] | None = None,
    *,
    export_root: Path | None = None,
    statements_only: bool = False,
    force: bool = False,
    since: str | None = None,
) -> int:
    """CLI entry point. Returns a process exit code."""
    from huske.config import load_config

    try:
        cfg: RuntimeConfig = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        print(f"config: {exc}")
        return 2

    root = export_root or cfg.export_root
    if not cfg.output_root.exists():
        print(f"[error] no transcripts at {cfg.output_root}")
        return 1

    result = export_days(
        cfg.output_root,
        root,
        statements_only=statements_only,
        force=force,
        since=since,
    )
    if result.total == 0:
        print(f"No transcripts found under {cfg.output_root}.")
        return 0

    print(f"huske export → {root}")
    print(f"  {len(result.written)} day(s) written, {len(result.skipped)} unchanged")
    for day, error in result.failed:
        print(f"  [warn] {day}: {error}")
    if result.written:
        print("")
        print("One file per day, statements first. Point a sync client (Drive, Dropbox,")
        print("iCloud, Obsidian) at that folder, or upload it to a Claude Project.")
        print("It is plaintext — see docs/integrations.md before syncing it off-device.")
    return 1 if result.failed else 0
