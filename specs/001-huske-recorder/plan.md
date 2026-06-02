# Implementation Plan: Huske — Always-On Terminal Audio Recorder & Transcriber

**Branch**: `001-huske-recorder` | **Date**: 2026-05-07 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-huske-recorder/spec.md`

## Summary

Build a Python-based terminal application (`huske`) that runs an always-on capture-transcribe loop on macOS: a sounddevice-driven audio thread captures microphone samples, a macOS system-audio backend captures computer output, a chunker rolls each source to per-source WAV files every N minutes (default 15), and a worker process consumes chunks via a queue and transcribes them locally with `mlx-whisper`. Finalized transcripts land as Markdown-with-YAML-frontmatter under `~/huske/transcripts/YYYY-MM-DD/`. The terminal foreground is a Rich live display showing recording state, current chunk progress, queue depth, last saved transcript, source levels, warnings, and runtime controls. Transcription runs in a separate process so a slow model never blocks capture; ungraceful exits leave audio fragments that are recovered on next start. v1 explicitly stops at the structured filesystem output — LLM/Todoist integration is downstream.

## Technical Context

**Language/Version**: Python 3.11+ (pattern matching, asyncio Task groups, faster typing).
**Primary Dependencies**:
- `sounddevice` (PortAudio bindings) — mic capture only.
- `pyobjc-framework-CoreAudio` (macOS-only) — system audio capture via Core Audio process tap on macOS 14.4+.
- `pyobjc-framework-ScreenCaptureKit` (macOS-only) — legacy system audio fallback on older macOS (`SCStream` / `SCContentFilter`).
- `pyobjc-framework-CoreMedia` — `CMSampleBuffer` / `CMBlockBuffer` access to read audio frames out of SCK callbacks.
- `numpy` — audio buffer manipulation.
- `soundfile` — WAV chunk persistence.
- `mlx-whisper` — local transcription on Apple Silicon via MLX.
- `rich` — terminal live UI (Layout + Live).
- `typer` — CLI argument parsing.
- `tomllib` (stdlib 3.11+) — config file parsing.
- `pydantic` v2 — config + metadata models.

**Storage**: Local filesystem only.
- Transcripts: `~/huske/transcripts/YYYY-MM-DD/<HHMMSS>_<sessionid8>_<seq>.md`
- Transient audio chunks: `~/huske/audio/<sessionid>/<seq>_<HHMMSS>_<source>.wav` (deleted post-transcription unless `--keep-audio`)
- Failed-transcription audio: moved to `~/huske/audio/incomplete/`
- Config: `~/.config/huske/config.toml`

**Testing**: `pytest` + `pytest-asyncio`. Unit tests for chunker, metadata serialization, filename disambiguation, and recovery scanner. Integration tests feed prerecorded WAV fixtures through the pipeline (mocked sounddevice input).

**Target Platform**: macOS 13 (Ventura) or newer on Apple Silicon. System audio is captured via Core Audio process tap on macOS 14.4+ and ScreenCaptureKit fallback on older macOS. No virtual audio driver, no Aggregate Device, no Audio MIDI Setup. The user grants the relevant macOS capture permission on first launch via the standard macOS prompt and never thinks about it again. Linux/Windows are explicit non-goals.

**Project Type**: CLI / desktop terminal app (single project, single binary entry point).

**Performance Goals**:
- Capture loop: stream 48 kHz stereo with <50 ms callback latency, no overruns over 8 hours.
- Transcription throughput: ≥1× real-time using `mlx-whisper` `base` model on M-series; chunk transcribed within 2 minutes of close (SC-002).
- TUI refresh: 4–10 Hz, ≤1 % CPU.

**Constraints**:
- 100 % local processing — no network egress for audio or transcripts.
- Audio durability — no captured second may be lost across graceful stop, hard kill, sleep/wake, or transcription failure.
- Transcription must run in a separate OS process from capture (Python GIL: a CPU-bound thread starves the audio thread otherwise).
- Single-user, single-machine.

**Scale/Scope**:
- One concurrent recording session per machine.
- Daily output volume: ~32 chunks/day × ~50 KB/transcript = ~1.5 MB transcripts/day; transient WAV peak ~150 MB (one in-flight chunk + small queue).
- Codebase target: <2 000 LOC for v1.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The repository's `.specify/memory/constitution.md` is the unedited placeholder template — no project principles have been ratified. With no project-specific gates to enforce, this plan applies speckit's implicit defaults: **simplicity** (single project, no premature abstractions), **testability** (pure-Python core decoupled from sounddevice / mlx-whisper for unit testing), and **observability** (structured logs to a sidecar log file plus on-screen warnings).

**Initial gate (pre-Phase 0)**: PASS — no violations to justify.
**Post-design gate (after Phase 1)**: PASS — design preserves single-project layout, no new heavyweight abstractions, no remote dependencies.

If/when the constitution is ratified, this plan should be re-evaluated.

## Project Structure

### Documentation (this feature)

```text
specs/001-huske-recorder/
├── plan.md                  # This file
├── spec.md                  # Feature specification
├── research.md              # Phase 0 — decisions, rationale, alternatives
├── data-model.md            # Phase 1 — entities and state transitions
├── quickstart.md            # Phase 1 — how to install, configure, run
├── contracts/               # Phase 1 — CLI surface + transcript file format
│   ├── cli.md
│   └── transcript-format.md
├── checklists/
│   └── requirements.md
└── tasks.md                 # Phase 2 (created later by /speckit.tasks)
```

### Source Code (repository root)

```text
huske/                       # Python package (importable as `huske`)
├── __init__.py
├── __main__.py              # `python -m huske` entry
├── cli.py                   # Typer app — `run`, `recover`, `doctor`, `autostart`
├── config.py                # Pydantic config model + TOML loader
├── doctor.py                # Setup diagnostics
├── run_loop.py              # Session orchestration
├── session.py               # RecordingSession orchestrator (lifecycle, IDs)
├── capture/
│   ├── __init__.py
│   ├── coordinator.py       # Mic + system-audio capture coordinator
│   ├── devices.py           # Microphone enumeration + validation
│   ├── system_audio.py      # ScreenCaptureKit system-audio backend
│   └── system_audio_tap.py  # Core Audio process-tap backend
├── chunker/
│   ├── __init__.py
│   └── rotator.py           # Buffer-to-WAV rotation on time boundary or shutdown
├── transcribe/
│   ├── __init__.py
│   ├── worker.py            # Subprocess entry: pulls chunks from queue, runs mlx-whisper
│   └── writer.py            # Markdown + frontmatter renderer, atomic write
├── recovery/
│   ├── __init__.py
│   └── scanner.py           # Detect orphaned audio fragments at startup
├── ui/
│   ├── __init__.py
│   ├── input.py             # Non-blocking terminal key reader
│   └── live.py              # Rich Layout + Live status panel
├── menubar.py               # macOS menu bar helper
├── output_readme.py         # Auto-generated transcript-root README
└── paths.py                 # Output root resolution + day-folder + filename rules

tests/
├── unit/
│   ├── test_chunker.py
│   ├── test_doctor.py
│   ├── test_paths.py
│   ├── test_writer.py
│   └── test_recovery.py
└── integration/
    ├── conftest.py          # WAV fixtures, fake sounddevice
    ├── test_pipeline_no_whisper.py
    ├── test_smoke.py
    ├── test_system_audio.py
    └── test_real_whisper.py

pyproject.toml               # Build, deps, entry point `huske = huske.cli:app`
README.md
```

**Structure Decision**: Single Python project, source under `huske/` at repo root (no `src/` indirection — keeps imports simple, this is a leaf application not a library to be vendored). Subpackages mirror the pipeline stages from the spec (capture → chunker → transcribe → writer) so each can be unit-tested in isolation. Tests split into `unit/` (pure functions) and `integration/` (full pipeline with WAV fixtures and a fake audio source).

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified.

No violations to justify — project structure is the simplest layout that supports the spec's requirements. The one non-trivial choice (multiprocessing for transcription) is required by Python's GIL, not added complexity, and is documented in `research.md`.
