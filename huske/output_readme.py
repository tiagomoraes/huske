"""Auto-generated README at the output root.

Documents the on-disk layout for downstream LLM agents (Claude Code, etc.).
"""

from __future__ import annotations

from pathlib import Path


_README_TEMPLATE = """# Huske transcripts

This directory is managed by the `huske` terminal app. Each subdirectory is a
local calendar date in `YYYY-MM-DD` form, holding all transcripts whose chunk
**start time** falls on that date. Each `.md` file is a single transcribed
audio chunk; filenames sort chronologically (`HHMMSS_<sessionid8>_<seq>.md`).

The YAML frontmatter at the top of each file is the authoritative metadata —
do not rely on the heading or filename alone. Schema (v1):

- `session_id`     — full session id (`YYYYMMDDTHHMMSS_<rand>`)
- `chunk_seq`      — monotonic sequence number within the session
- `date`           — local date of `start_time`
- `start_time`     — ISO 8601, timezone-aware
- `end_time`       — ISO 8601, timezone-aware
- `duration_seconds` — configured chunk duration (typically 900)
- `duration_actual_seconds` — what was actually captured (may be shorter)
- `gap_seconds`    — total silence/disconnect gaps within the chunk
- `audio_sources`  — subset of [microphone, system]
- `model`          — `<engine>:<size>`, e.g. `mlx-whisper:base`
- `language`       — ISO 639-1 or `auto` if undetected
- `incomplete`     — true if produced from recovery or graceful-stop
- `huske_version`  — semver of the producing huske binary

To query: an LLM agent can be pointed at this directory and asked to read
files by date/time directly. No bespoke tooling is required.
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
