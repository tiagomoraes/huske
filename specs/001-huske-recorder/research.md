# Phase 0 — Research: Huske

**Date**: 2026-05-07
**Branch**: `001-huske-recorder`

This document records the technology and design decisions made before drafting data models and contracts. Each decision states what was chosen, why, and what was rejected.

---

## R1. Implementation language

**Decision**: Python 3.11+.

**Rationale**:
- Whisper-class transcription has the most mature, fastest local bindings in Python (`faster-whisper`, `mlx-whisper`, OpenAI reference). Iteration cost is lowest.
- Audio capture via `sounddevice` (PortAudio) is straightforward for the microphone, while macOS system audio is handled through built-in capture APIs without virtual devices.
- Rich/Textual provide TUI quality matching the "interface bonitinha" goal without writing terminal control codes by hand.
- The user's other tooling (Claude Code, MCP integrations) is Python/JS friendly; downstream LLM consumption of transcripts won't care about the producer's language.

**Alternatives considered**:
- **Rust** with `cpal` + `whisper-rs` + `ratatui`: produces a single static binary and has no GIL constraint. Rejected for v1 because (a) `whisper-rs` lags upstream Whisper improvements, (b) audio device + virtual loopback ergonomics on macOS are friendlier from PortAudio than from CoreAudio bindings, (c) iteration speed matters more than runtime for a personal tool.
- **Swift / native macOS** with ScreenCaptureKit: best system-audio capture story (no virtual device required), but locks the project to macOS, ships no Whisper bindings out of the box, and increases time-to-first-transcript significantly.
- **Go**: TUI story (`bubbletea`) is good but Whisper bindings are less mature than Python's.

---

## R2. Local transcription engine

**Decision**: `mlx-whisper`, default model `base`, configurable.

**Rationale**:
- Runs on the M-series GPU via MLX and is materially faster than the prior CTranslate2 path on Apple Silicon.
- Keeps the product target focused on Apple Silicon, which is also where the macOS system-audio capture story is strongest.
- Models download on first use and cache locally through Hugging Face tooling, no manual setup beyond installing Huske.

**Alternatives considered**:
- **`faster-whisper`** (CTranslate2 backend): worked in early prototypes, but MLX is faster and simpler for the Apple Silicon-only target.
- **`whisper.cpp` via Python bindings**: also fast, but pre-built wheels are less consistent and model file management is manual.
- **OpenAI reference `whisper`**: simplest dependency, but ~5× slower; would risk SC-002 on slower hardware.

**Configuration knobs exposed**:
- `model`: model size (`tiny`, `base`, `small`, `medium`, `large-v3`); default `base`.
- `compute_type`: kept for back-compat; `float32` opts out of fp16 inference, other values use the MLX default.
- `device`: kept for back-compat; `cuda` is rejected on macOS.

---

## R3. Audio capture on macOS — mic + system audio

**Decision (revised)**: Two parallel sources, written separately and merged at transcript time:
- **Microphone**: `sounddevice` (PortAudio bindings) reading from the system default mic (or a user-selected mic via `--input-device`). 1 channel, mono float32.
- **System audio**: Core Audio process tap on macOS 14.4+ (`AudioHardwareCreateProcessTap`) with ScreenCaptureKit fallback on older macOS. Both paths produce mono float32 blocks at the configured sample rate.

A `CaptureCoordinator` (`huske/capture/coordinator.py`) runs both sources concurrently, each pushing into its own bounded mono ring buffer. A mixer thread drains both at 50 ms cadence and forwards source-tagged blocks to the chunker. If system audio fails (permission missing, framework error) the coordinator degrades to mic-only with a sticky warning surfaced in the UI.

**Rationale**:
- Core Audio process tap is decoupled from screen capture and survives Google Meet / Zoom screen-sharing sessions that can interrupt ScreenCaptureKit audio capture. ScreenCaptureKit remains a useful fallback on older macOS. No virtual audio driver, no Aggregate Device, no Audio MIDI Setup.
- Eliminates the entire class of BlackHole/Aggregate-Device fragility (driver gets revoked on macOS upgrades, Aggregate Device deleted by audio-config resets, AirPods auto-switching breaks system-output routing).
- PyObjC's bindings expose `SCStream` / `SCContentFilter` / `CMSampleBuffer` / `CMBlockBufferCopyDataBytes` directly — no Swift bridge, no compiled helper binary, no build step. The whole bridge is one Python module.
- `excludesCurrentProcessAudio = true` prevents capturing huske's own terminal output, avoiding feedback loops.
- Keeping per-source WAVs lets the transcription worker preserve source labels and align segment timestamps back to wall-clock time.

**Permission model**: macOS grants capture permissions per-binary-path (i.e., per Python interpreter). Core Audio tap may prompt for Audio Capture or a screen-recording-adjacent permission depending on the OS minor version. ScreenCaptureKit fallback and screenshots use Screen Recording. `huske doctor` validates the effective backend.

**Alternatives considered**:
- **BlackHole 2ch + Aggregate Device** (the v0.0 plan): simpler code path but compound-interest fragility — every macOS update is a coin flip on whether the driver still loads, every audio reset deletes the Aggregate Device, every AirPods reconnection silently changes system output away from the multi-output device. Rejected for a personal-use tool that should "just work" indefinitely.
- **Native Swift helper (SCStream in Swift, output raw PCM via stdout pipe)**: cleaner Swift code than PyObjC delegates but adds a build step (Xcode CLT required at install time) and a separate compiled artifact to ship. PyObjC route is simpler given how well the bindings cover SCK.
- **CoreAudio HAL plugin**: too heavyweight; not a viable v1 option.
- **Tap individual app outputs**: not a stable public API on macOS.

**Capture parameters**:
- Mic: 48 kHz, 1ch, float32, blocksize 1024 (~21 ms at 48 kHz).
- System: 48 kHz mono blocks from Core Audio tap or ScreenCaptureKit fallback.
- Mixer cadence: 50 ms (2400 frames at 48 kHz).
- Output: one 1ch, 48 kHz WAV per active source per chunk.

`huske doctor` will:
1. List input devices.
2. Validate the resolved mic.
3. Run a ~1-second mic sample and report peak dB.
4. Validate the configured system-audio backend.
5. Verify output / audio paths are writable.

---

## R4. Concurrency model — capture vs. transcription

**Decision**: Three execution contexts, hard isolation between them.
1. **Audio callback thread** (sounddevice-owned): only writes raw frames into a shared lock-free ring buffer. No I/O, no allocation in the hot path.
2. **Main thread** (asyncio): runs the Rich Live UI, the chunk-rotation timer, and chunk submission to the transcription queue. Dispatches chunk-finalization disk writes to a small ThreadPoolExecutor.
3. **Transcription worker subprocess** (`multiprocessing.Process`): pulls chunk file paths from a `multiprocessing.Queue`, runs `mlx-whisper`, writes transcript markdown via the writer module, and posts a completion event back to a result queue.

**Rationale**:
- The Python GIL makes a transcription thread an unacceptable risk: Whisper inference would starve the audio callback and the UI loop. A subprocess sidesteps this entirely.
- Capture must never block — it's the only side of the pipeline that loses data on a stall. Keeping it in the sounddevice callback (separate thread, no Python-level locking on its hot path) is essential.
- Disk writes for finalized WAV chunks are O(seconds) and must not block the audio callback either; they're handed to a thread pool from the asyncio loop.
- `multiprocessing.Queue` is sufficient — chunks are large (multi-MB WAVs) but we pass *paths*, not bytes, across the process boundary.

**Failure modes handled**:
- Worker subprocess crash → main process detects exit, restarts the worker, marks any in-flight chunk as needing retry.
- Slow transcription (queue depth grows) → UI shows queue depth; chunks remain on disk until processed; no audio is dropped.

**Alternatives considered**:
- **`asyncio` only with thread-pool transcription**: GIL contention with the audio callback is a real risk under sustained CPU load.
- **Two processes communicating via filesystem only (no queue)**: simpler but adds polling latency. Queue is fine.

---

## R5. Chunk rotation strategy

**Decision**: Time-boundary rotation with handoff via short overlap window.
- Maintain two WAV writers per session: a *current* writer and a *next* writer.
- At T-0.5 s before the configured boundary, open the next writer.
- At T-0, switch the audio callback to feed the next writer; close the current writer; submit it to the transcription queue.
- Handoff happens within a single audio callback to guarantee zero dropped frames.

**Rationale**:
- A naïve "close-then-open" sequence can drop a callback's worth of audio between the close and the open.
- The double-writer pattern is standard in audio recorders (e.g., Audacity's "split on silence").
- 0.5 s lead time is generous; actual handoff is sub-millisecond.

**Filename convention** (per FR-014/15/17):
- Chunk WAV (transient): `~/huske/audio/<sessionid>/<chunk_seq>_<HHMMSS>_<source>.wav` where `<chunk_seq>` is a zero-padded monotonic counter within the session and `<source>` is `microphone` or `system`. One WAV per active source per chunk; the recovery scanner also accepts the legacy unsuffixed form (`<chunk_seq>_<HHMMSS>.wav`) for sessions captured before the source-split change.
- Transcript: `~/huske/transcripts/YYYY-MM-DD/<HHMMSS>_<sessionid8>_<chunk_seq>.md`. Including the session-id-prefix and chunk sequence guarantees no two runs collide on filename even at sub-second restart.

---

## R6. Transcript file format

**Decision**: Markdown with YAML frontmatter.

```markdown
---
session_id: 2026-05-07T09-00-00_8a3f
chunk_seq: 14
date: 2026-05-07
start_time: 12:30:00-03:00
end_time: 12:45:00-03:00
duration_seconds: 900
duration_actual_seconds: 900
audio_sources: [microphone, system]
model: mlx-whisper:base
language: pt
incomplete: false
---

# 12:30 – 12:45 (Wed 2026-05-07)

[transcript text here, with optional inline timestamps every N seconds]
```

**Rationale**:
- Markdown renders nicely in any editor and in the eventual LLM consumer's view.
- YAML frontmatter is a documented, parser-friendly metadata block — Claude Code, Obsidian, Dataview, and most tooling already speak it (FR-018).
- Embedding metadata at the top satisfies FR-016 even if a single file is opened in isolation.
- Plain text body keeps the file LLM-context-friendly (no escape sequences).

**Alternatives considered**:
- **JSON one file per chunk**: machine-friendly but unpleasant to read directly.
- **`.txt` plus sidecar `.json`**: two files per chunk, more bookkeeping.
- **SQLite**: better for query at scale, but breaks the "plain files an LLM agent can read" requirement (FR-018).

---

## R7. Output root and day folders

**Decision**:
- Default output root: `~/huske/transcripts/`. Override via `--output-root` flag or `output_root` in config.
- Day folder: `YYYY-MM-DD` based on the chunk's **start time in local timezone**. Chunks that straddle midnight are filed under their start-time date; the metadata records the actual window.
- Audio scratch root: `~/huske/audio/<sessionid>/`. Cleaned on successful transcription unless `--keep-audio` is set.

**Rationale**:
- `~/huske/` keeps the user's home tidy and is a path that's trivial to point a downstream LLM agent at.
- Local timezone for day folders matches user intuition ("show me yesterday's transcripts"). Storing absolute timestamps in metadata preserves precision.

**Alternatives considered**:
- `$XDG_DATA_HOME/huske` — more "correct" on Linux, but on macOS users rarely set XDG and `~/huske` is more discoverable. Configurable, not the default.

---

## R8. Recovery of orphaned audio (FR-023)

**Decision**: At startup, scan `~/huske/audio/` for session subdirectories that don't have a running session-lock file. For each orphan:
1. Inspect each WAV chunk: if it's a valid, non-empty WAV, enqueue it for transcription against the same metadata it was tagged with at rotation time (start time stored in filename).
2. If a WAV is truncated/invalid (hard-kill mid-write), move it to `~/huske/audio/incomplete/` and log a warning.
3. After all chunks are processed, delete the empty session subdirectory.

A *session lock* is a file `~/huske/audio/<sessionid>/.lock` containing the running PID; if the file exists but the PID is gone (or doesn't match a running `huske` process), the session is treated as orphaned.

**Rationale**:
- Satisfies "MUST NOT silently delete unsaved audio" (FR-023).
- Recovery is opportunistic — if it fails, audio stays in `incomplete/` for the user (or a future tool) to inspect.
- PID-based locking is sufficient for a single-user tool; no need for fcntl flock.

---

## R9. Sleep / wake handling (FR-024)

**Decision**: Use sounddevice stream callbacks' device-state info plus a wall-clock heartbeat:
- Each audio callback updates a "last-callback" wall-clock timestamp.
- A monitor task in the asyncio loop checks this timestamp every second; if more than 5 s have elapsed since the last callback, treat as a sleep/disconnect event.
- On detection: close the current chunk (it becomes a shorter chunk per FR-024), submit for transcription, and attempt to restart the input stream. The metadata records `gap_seconds` if we recover.

**Rationale**:
- macOS suspends user-space processes on sleep; sounddevice callbacks simply stop firing. There's no portable "sleep notification" API in Python without heavy dependencies.
- A 5-second threshold is well above any normal callback gap and below human-perceptible "the app froze" tolerance.

**Alternatives considered**:
- Subscribing to `IORegisterForSystemPower` via PyObjC: cleaner but adds a macOS-specific dependency for what a heartbeat handles fine.

---

## R10. Configuration loading

**Decision**: Three-layer config with later layers overriding earlier:
1. Compiled defaults (Pydantic model defaults).
2. Config file: `~/.config/huske/config.toml` if present.
3. CLI flags via Typer.

Fields include `chunk_minutes`, `output_root`, `audio_root`, `logs_root`,
`model`, `compute_type`, `device`, `language`, `keep_audio`, `input_device`
(microphone name), screenshot settings, menu-bar settings, and
`system_audio_backend`.

**Rationale**: Standard pattern. TOML is stdlib in 3.11+. Pydantic provides validation and clear error messages.

---

## R11. TUI design

**Decision**: Rich `Live` + `Layout` with three panels:
- **Header**: app name, version, session id, output root.
- **Main**: large recording-state indicator (●/○), elapsed-in-chunk, countdown-to-next-rotation, audio level bars (peak per channel), queue depth.
- **Footer**: rolling list of last 3–5 events (chunk N saved → path; warnings; errors), color-coded.

Refresh rate: 8 Hz. Updates driven from the asyncio loop via a `RenderState` dataclass that the UI re-renders.

**Rationale**:
- Matches the "interface bonitinha" requirement without committing to a full Textual app.
- Rich is already a near-universal dependency in Python TUI work; small footprint.
- 8 Hz is smooth-looking and uses negligible CPU.

**Alternatives considered**:
- **Textual**: full app framework with reactive widgets. Overkill for a status display.
- **Plain print scroll**: violates FR-019 (non-scrolling).

---

## R12. Logging and observability

**Decision**: Structured JSON logs to `~/huske/logs/<sessionid>.log` via `structlog`, plus visible UI events for warnings/errors. Log levels: INFO for lifecycle, WARNING for recoverable issues (device hiccups, transcription retries), ERROR for transcription failures and write errors.

**Rationale**: Forensic logs let the user (or Claude Code) diagnose post-hoc without cluttering the live UI.

**Alternatives considered**: stdlib `logging` with a JSON formatter would also work and avoids a dep — fine fallback if we want to drop `structlog`.

---

## R13. Testing strategy

**Decision**:
- **Unit tests** (pytest) for: filename derivation (`paths.py`), metadata serialization (`writer.py`), recovery scanner (`recovery/scanner.py`), config loading (`config.py`). All pure functions or filesystem-only — no audio.
- **Integration tests** that drive the full pipeline by feeding prerecorded WAVs through a fake `sounddevice` stream and asserting that the resulting `transcripts/` tree matches expectations. Use a tiny pre-trained model (`tiny`) to keep CI fast — or stub the transcription worker entirely with a fake that emits canned text.
- **No live-audio tests in CI** — they'd be flaky and slow.

**Rationale**: This split keeps unit tests fast and deterministic while still exercising the real chunker → writer → recovery flow against synthetic data.

---

## Open items

None. All NEEDS CLARIFICATION from the Technical Context have been resolved above.
