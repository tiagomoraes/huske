# Contract: Transcript File Format

**Status**: Phase 1 design — frozen for v1
**Source**: `spec.md` FR-014, FR-015, FR-016, FR-017, FR-018; `research.md` R6, R7

This is the contract a downstream LLM agent (e.g., Claude Code) consumes. Anything described here is stable for v1.

---

## Directory layout

```text
<output_root>/                            # default: ~/huske/transcripts/
├── 2026-05-06/
│   ├── 084500_8a3f2c19_001.md
│   ├── 090000_8a3f2c19_002.md
│   └── …
├── 2026-05-07/
│   ├── 091500_b71e0440_001.md
│   ├── 093000_b71e0440_002.md
│   └── …
└── README.md                             # auto-generated; documents this layout
```

- One directory per local calendar date (`YYYY-MM-DD`) of the chunk's **start time**.
- A chunk that straddles midnight stays in its start-date folder; metadata records the actual window.
- Lexicographic sort of filenames within a folder = chronological order.

---

## Filename format

```
<HHMMSS>_<sessionid8>_<chunk_seq:03d>.md
```

| Component | Meaning |
|---|---|
| `HHMMSS` | Chunk start time, 24h, local tz, no separators. |
| `sessionid8` | First 8 chars of the session id (`<hash>` portion of `YYYYMMDDTHHMMSS_<hash>`). Disambiguates rapid restarts (FR-017). |
| `chunk_seq` | Zero-padded sequence number within the session, starting at `001`. |

Example: `091500_8a3f2c19_002.md` = chunk 2 of session `8a3f2c19`, started at 09:15:00 local.

**Disambiguation guarantee**: Two chunks from different sessions cannot collide because `sessionid8` differs (with overwhelming probability). Two chunks from the same session cannot collide because `chunk_seq` is monotonic. Two sessions started within the same second produce different `sessionid8` values (random suffix).

---

## File format

UTF-8 Markdown with YAML frontmatter. Both blocks are mandatory.

### Frontmatter

```yaml
---
session_id: 20260507T091500_8a3f2c19
chunk_seq: 2
date: 2026-05-07
start_time: 2026-05-07T09:30:00-03:00
end_time: 2026-05-07T09:45:00-03:00
duration_seconds: 900
duration_actual_seconds: 900.0
gap_seconds: 0.0
audio_sources:
  - microphone
  - system
model: mlx-whisper:base
language: pt
incomplete: false
huske_version: 0.5.0
---
```

| Key | Type | Notes |
|---|---|---|
| `session_id` | string | Full session id. |
| `chunk_seq` | integer | Within session, ≥1. |
| `date` | YYYY-MM-DD | Local date of `start_time`. |
| `start_time`, `end_time` | ISO 8601 with offset | Always tz-aware. |
| `duration_seconds` | integer | Configured chunk duration. |
| `duration_actual_seconds` | float | What was actually captured. May be < `duration_seconds` for partial chunks. |
| `gap_seconds` | float | Total silence/disconnect gaps within the chunk; 0 if continuous. |
| `audio_sources` | list[string] | Subset of `["microphone", "system"]`. Reflects what was effectively captured (may shrink if a source dropped mid-chunk). |
| `model` | string | `<engine>:<size>`. |
| `language` | string | ISO 639-1 or `auto` if undetected. |
| `incomplete` | boolean | `true` if produced from recovery, graceful-stop short chunk, or partial transcription. |
| `huske_version` | string | Semver of the producing huske binary. |

### Body

```markdown
# 09:30 – 09:45 (Wed 2026-05-07)

[09:30:00 · system] Olá, vamos começar a reunião.

[09:30:01 · mic] Oi, tudo certo.

[09:30:08 · system] Hoje queria revisar o roadmap.
```

- The H1 line is human-readable and may be reformatted; tooling should rely on the frontmatter, not the heading.
- Each contiguous run of same-source segments is one paragraph prefixed with `[HH:MM:SS · <source>]`, where:
  - `HH:MM:SS` is the local-time start of the run's first segment (chunk `start_time` plus the segment offset within its WAV) — it is the run's head, not periodic.
  - `<source>` is `mic` for microphone or `system` for system audio.
- Runs are formed from segments sorted ascending by start time; consecutive
  same-source segments are merged into one run. Concurrent segments from
  different sources appear back-to-back in source order, making overlapping
  speech (e.g., you and a remote participant talking at once) visible to the
  reader.
- A run is also broken when it would otherwise exceed an internal cap
  (~90 s of segment span) so long single-source monologues keep periodic
  timestamp anchors instead of collapsing every interior segment behind one
  head timestamp.
- A chunk with no detected speech writes the body as: `_(no speech detected)_`.

---

## Auto-generated `README.md`

Huske writes (and refreshes if missing) a `<output_root>/README.md` that documents this layout for any tool or human pointed at the directory:

```markdown
# Huske transcripts

This directory is managed by the `huske` terminal app. Each subdirectory is a
local calendar date in `YYYY-MM-DD` form, holding all transcripts whose chunk
start time falls on that date. Each `.md` file is a single transcribed audio
chunk; filenames sort chronologically (`HHMMSS_<sessionid8>_<seq>.md`). The
YAML frontmatter at the top of each file is the authoritative metadata.

To query: an LLM agent can be pointed at this directory and asked to
read files by date/time. No bespoke tooling is required.
```

---

## What downstream consumers can rely on

1. **Stable filename glob**: `<output_root>/<YYYY-MM-DD>/<HHMMSS>_<id>_<seq>.md`.
2. **Stable frontmatter keys** listed above. New keys may be added; existing keys will not be removed in v1.x.
3. **Authoritative time window** is `start_time` / `end_time` in frontmatter, not filename.
4. **Sort order**: directory listing sort = chronological order, both within a day and across days.
5. **No companion files**: a transcript is a single self-contained `.md` file. Audio is not a sibling unless `--keep-audio`.

## What is NOT a contract

- The exact paragraphing inside the body (depends on the model).
- The wording of the H1 heading.
- The presence of optional inline timestamps (future flag).
- The schema of the sidecar log files in `~/huske/logs/`.
