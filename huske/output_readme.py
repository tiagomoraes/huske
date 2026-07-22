"""Auto-generated README at the output root.

Documents the on-disk layout for downstream LLM agents (Claude Code, etc.).
"""

from __future__ import annotations

from pathlib import Path

_README_TEMPLATE = """# Huske transcripts

This directory is managed by `huske`. It is a day-organized,
LLM-readable log of what was said on this machine. Point an agent here and ask
about a day, a time range, or a topic — no bespoke tooling is required.

## Layout

- One subdirectory per local calendar date (`YYYY-MM-DD`), holding every
  transcript whose chunk **start time** falls on that date.
- Each `.md` file is a single transcribed audio chunk. Filenames sort
  chronologically: `HHMMSS_<sessionid8>_<seq>.md`.
- A chunk is **not** a fixed time slice. huske splits on real pauses in speech:
  a chunk opens when speech starts and closes after a pause (default 60 s) or a
  safety cap. So each file is a self-contained stretch of conversation, and
  silent periods produce no file.

## Frontmatter (authoritative metadata — prefer it over the heading/filename)

- `session_id`     — full session id (`YYYYMMDDTHHMMSS_<rand>`); a continuous
                     recording shares one session id across its chunks
- `chunk_seq`      — monotonic sequence number within the session
- `date`           — local date of `start_time`
- `start_time` / `end_time` — ISO 8601, timezone-aware; the real recorded window
- `duration_seconds` — recorded length of the chunk
- `duration_actual_seconds` — seconds of audio actually captured
- `gap_seconds`    — total silence/disconnect gaps within the chunk
- `audio_sources`  — subset of [microphone, system] effectively captured
- `model`          — `<engine>:<size>`, e.g. `parakeet:tdt-0.6b-v3`
- `language`       — ISO 639-1, or `auto` when the engine auto-detects
- `incomplete`     — true only for recovery/partial chunks
- `huske_version`  — semver of the producing huske binary

## Reading the body

Each paragraph is one run of speech, prefixed `[HH:MM:SS · <source>]`:

- **`mic`** — this computer's microphone: the local person (you), and anyone
  in the room.
- **`system`** — audio played by this computer: the remote side of a call, a
  video, music — i.e. the people/media you were listening to.

The two sources are captured separately and interleaved by time, so an overlap
of `mic` and `system` runs means both sides talked at once. When recording on
speakers (no headphones), the system audio that leaks into the microphone is
suppressed and de-duplicated, so it is **not** double-counted on the `mic`
side. Timestamps are local wall-clock (`start_time` + offset within the chunk).

For semantic search across all transcripts, the optional `huske mcp` server
lets an agent query by meaning; otherwise just read the files by date/time.
"""


def render_readme() -> str:
    return _README_TEMPLATE


def ensure_output_readme(output_root: Path) -> Path:
    """Write README.md at ``output_root`` if missing or content-drifted. Idempotent."""
    output_root.mkdir(parents=True, exist_ok=True)
    target = output_root / "README.md"
    desired = render_readme()
    if target.exists():
        try:
            current = target.read_text(encoding="utf-8")
        except OSError:
            current = ""
        if current == desired:
            return target
    target.write_text(desired, encoding="utf-8")
    return target
