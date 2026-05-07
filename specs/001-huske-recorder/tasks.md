---

description: "Implementation task list for Huske — Always-On Terminal Audio Recorder & Transcriber"
---

# Tasks: Huske — Always-On Terminal Audio Recorder & Transcriber

**Input**: Design documents from `/specs/001-huske-recorder/`
**Prerequisites**: plan.md (✓), spec.md (✓), research.md (✓), data-model.md (✓), contracts/ (✓), quickstart.md (✓)

**Tests**: Included. The plan explicitly calls for `pytest` + `pytest-asyncio` (plan.md "Testing" section, research.md R13). Tests are not strictly TDD-first but are written alongside the code they cover so each story can be validated independently.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing. Phase 1 (Setup) and Phase 2 (Foundational) are shared prerequisites; Phases 3–5 deliver one user story each in priority order; Phase 6 covers polish.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story this task belongs to (`[US1]`, `[US2]`, `[US3]`). Setup, Foundational, and Polish phases have no story label.
- All file paths are absolute repo-relative (repo root is `/Users/tiagomoraes/code/huske/`).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization — Python package skeleton, dependency manifest, tooling.

- [x] T001 Create Python package skeleton at `huske/` with empty `huske/__init__.py` (with `__version__ = "0.1.0"`) and `huske/__main__.py` that imports and runs `huske.cli:app`
- [x] T002 Create `pyproject.toml` at repo root declaring: project metadata (name `huske`, Python `>=3.11`), runtime deps (`sounddevice`, `numpy`, `soundfile`, `faster-whisper`, `rich`, `typer`, `pydantic>=2`, `structlog`, `tomli; python_version<'3.11'`), dev deps under `[project.optional-dependencies].dev` (`pytest`, `pytest-asyncio`, `ruff`, `mypy`), and console script entry point `huske = huske.cli:app`
- [x] T003 [P] Add `ruff` and `mypy` configuration to `pyproject.toml` (line length 100, target Python 3.11, mypy `strict = true` with `disallow_untyped_defs`)
- [x] T004 [P] Add `pytest` configuration to `pyproject.toml` `[tool.pytest.ini_options]` with `testpaths = ["tests"]`, `asyncio_mode = "auto"`, and a `markers` entry for `integration`
- [x] T005 [P] Create test scaffolding: `tests/__init__.py`, `tests/unit/__init__.py`, `tests/integration/__init__.py`, and an empty `tests/integration/conftest.py`
- [x] T006 [P] Create `.gitignore` covering `__pycache__/`, `.venv/`, `dist/`, `.pytest_cache/`, `.ruff_cache/`, `.mypy_cache/`, `*.egg-info/`

**Checkpoint**: `uv pip install -e ".[dev]"` succeeds and `pytest -q` reports zero tests collected.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Cross-cutting infrastructure that every user story depends on. No user story work begins until this phase is complete.

**⚠️ CRITICAL**: Phases 3–5 cannot start until this phase is done.

- [x] T007 Implement `RuntimeConfig` Pydantic model + three-layer loader (defaults → TOML at `~/.config/huske/config.toml` → CLI overrides) in `huske/config.py`. Validate ranges per `data-model.md` §4 (chunk_minutes 1–60, model enum, device enum, reject `cuda` on Apple Silicon).
- [x] T008 [P] Implement path utilities in `huske/paths.py`: `generate_session_id() -> str` (`YYYYMMDDTHHMMSS_<rand4hex>`), `output_root(cfg)`, `audio_root(cfg, session_id)`, `day_folder(cfg, dt)`, `transcript_filename(chunk) -> Path` (per `contracts/transcript-format.md` filename format), `audio_chunk_path(session_id, chunk_seq, start_dt) -> Path`, `lock_path(audio_root) -> Path`. Centralize `~` expansion here.
- [x] T009 [P] Implement structured logging setup in `huske/logging_setup.py`: configure `structlog` to emit JSON lines to `~/huske/logs/<session_id>.log` plus an optional console renderer when `--no-ui` is set. Provide `get_logger(name)` helper.
- [x] T010 [P] Implement audio device enumeration + validation in `huske/capture/devices.py`: `list_input_devices()`, `resolve_input_device(name | None) -> dict`, `validate_device(device) -> ValidationReport` (channels, sample rate, host API). No live capture yet.
- [x] T011 Implement `RecordingSession` skeleton in `huske/session.py`: dataclass per `data-model.md` §1, state machine transitions (`starting → recording → stopping → stopped`, plus `failed`), lock-file lifecycle (`acquire_lock(session_id, audio_root)`, `release_lock()`, `is_lock_alive(lock_path)` checks PID via `os.kill(pid, 0)`). No capture wiring yet.
- [x] T012 Create Typer CLI shell in `huske/cli.py`: `app = typer.Typer()`, three command stubs `run`, `recover`, `doctor` with the flag signatures from `contracts/cli.md`. Each stub prints "not yet implemented" and exits 0. Wire `python -m huske` and `huske` entry to it.
- [x] T013 [P] Add `tests/unit/test_paths.py` covering `transcript_filename`, `day_folder`, `audio_chunk_path`, and `generate_session_id` (uniqueness across rapid calls, sortable format)
- [x] T014 [P] Add `tests/unit/test_config.py` covering: defaults, TOML override, CLI override, validation errors (chunk_minutes out of range, unknown model, cuda-on-mac rejection)

**Checkpoint**: `huske --help` lists all three subcommands. `pytest tests/unit/test_paths.py tests/unit/test_config.py -q` passes.

---

## Phase 3: User Story 1 — Always-On Capture That Yields Transcripts (Priority: P1) 🎯 MVP

**Goal**: Continuous mic + system-audio capture that auto-rotates every 15 minutes, transcribes each chunk locally with `faster-whisper` in a separate process, and writes a Markdown transcript with full frontmatter to the day-organized output tree. Graceful stop finalizes the partial chunk. Recovery on startup reclaims orphaned audio from prior crashes.

**Independent Test**: Run `huske run` for ~17 minutes while occasionally speaking; confirm a transcript file appears under `~/huske/transcripts/YYYY-MM-DD/<HHMMSS>_<id>_001.md` containing the spoken text and that recording continued into a second chunk without gaps. Then `kill -9` huske mid-chunk, restart, and confirm `huske recover` (or auto-recovery) processes the orphan WAV.

### Tests for User Story 1

- [x] T015 [P] [US1] Add `tests/integration/conftest.py` fixtures: `fake_audio_stream` (replays a WAV via a `sounddevice` monkeypatch into the real callback), `tiny_model` (forces `faster-whisper` to use the `tiny` size for speed), `tmp_huske_root` (isolated `output_root` and `audio_root`), and a `canned_transcription_worker` fixture that swaps `faster-whisper` for a deterministic stub
- [x] T016 [P] [US1] Add `tests/unit/test_chunker.py` covering: chunk rotation at the configured boundary, double-writer handoff produces zero dropped frames (verify by sample-count accounting), short chunk on graceful stop carries `actual_duration_seconds < expected_duration_seconds`
- [x] T017 [P] [US1] Add `tests/unit/test_writer.py` covering: full frontmatter schema (every key from `contracts/transcript-format.md`), atomic write (write to `.tmp` + rename), silent-chunk body (`_(no speech detected)_`), correct H1 heading
- [x] T018 [P] [US1] Add `tests/unit/test_recovery.py` covering: orphan detection by dead-PID lock, valid-WAV → enqueued, truncated-WAV → moved to `audio/incomplete/`, empty session dir cleaned up after recovery
- [x] T019 [US1] Add `tests/integration/test_end_to_end.py`: feed a 90-second WAV through `fake_audio_stream` with `chunk_minutes=0.25` (15 s, allowed by lowering the test bound), assert that 6 transcript files land in the expected day folder with sortable filenames and parseable frontmatter
- [x] T020 [US1] Add `tests/integration/test_graceful_stop.py`: start a session, after 8 s of fake audio send SIGINT, assert that exactly one transcript file is produced with `actual_duration_seconds ≈ 8.0` and `incomplete: true` in frontmatter

### Implementation for User Story 1

- [x] T021 [P] [US1] Implement `AudioChunk` dataclass + state machine in `huske/chunker/__init__.py` (or a `models.py` if cleaner) per `data-model.md` §2
- [x] T022 [P] [US1] Implement audio capture stream in `huske/capture/stream.py`: open a `sounddevice.InputStream` at 48 kHz / 2ch / float32 / blocksize 1024; callback writes frames into a thread-safe ring buffer; expose `start()`, `stop()`, `last_callback_at` (wall-clock for sleep/wake monitor), `read_frames(n)`, `pop_block()` for the chunker
- [x] T023 [US1] Implement chunker rotation in `huske/chunker/rotator.py`: maintains *current* and *next* `soundfile.SoundFile` writers; rotation scheduled at `chunk_started_at + chunk_minutes`; pre-opens the next writer 0.5 s before the boundary; in a single audio callback closes current + switches to next; on close emits an `AudioChunk(state="finalized")` event
- [x] T024 [P] [US1] Implement transcript writer in `huske/transcribe/writer.py`: `write_transcript(transcript: Transcript, path: Path)` renders YAML frontmatter (using `yaml.safe_dump`) + Markdown body, writes atomically (`.tmp` + `os.replace`), handles silent-chunk body, ensures parent dir exists
- [x] T025 [US1] Implement transcription worker subprocess in `huske/transcribe/worker.py`: `multiprocessing.Process` target that loops on a `multiprocessing.Queue`, instantiates `faster_whisper.WhisperModel(cfg.model, compute_type=cfg.compute_type, device=cfg.device)`, transcribes each chunk path, builds a `Transcript`, calls `writer.write_transcript`, posts result back on a result queue. On crash: parent restarts and re-queues the in-flight chunk
- [x] T026 [US1] Implement orphan recovery in `huske/recovery/scanner.py`: `scan_orphans(audio_root) -> list[OrphanSession]`; for each orphan, validate WAVs (header check + non-zero duration), enqueue valid ones, move truncated ones to `audio/incomplete/<session_id>/`, delete now-empty session directory. Returns a summary record
- [x] T027 [US1] Wire `huske run` end-to-end in `huske/cli.py`: load config, run startup recovery (calls `recovery.scan_orphans` and feeds chunks into the new session's queue), validate input device (calls `capture.devices.validate_device`, exits 3 with actionable message on failure), create session + lock, spawn transcription worker, start `capture.stream`, run the `chunker.rotator` loop in asyncio, install SIGINT handler that triggers graceful stop (close current chunk → finalize → submit → drain queue → release lock → exit 0). For US1 the UI is plain log lines; Rich `Live` lands in US3
- [x] T028 [US1] Implement `huske recover` command in `huske/cli.py`: load config, run `recovery.scan_orphans`, spawn a one-shot transcription worker, drain the queue with a progress log line per chunk, print summary (`<n> sessions recovered, <m> chunks transcribed, <k> moved to incomplete`), exit 0 / 1 per `contracts/cli.md`
- [x] T029 [US1] Add audio-source tagging to `AudioChunk`: at chunk open, record `audio_sources = ["microphone", "system"]` (or just one if degraded); `capture.stream` posts a "source dropped" event when a channel goes silent for >5s mid-chunk so the chunker can mutate `audio_sources` before close

**Checkpoint**: User Story 1 is fully functional. `huske run` records continuously, produces correct transcripts at each rotation, finalizes the partial chunk on Ctrl+C, and `huske recover` reclaims orphans from prior crashes. SC-001, SC-002, SC-005, SC-007, SC-008 should be measurable now.

---

## Phase 4: User Story 2 — Organized Daily Knowledge Base on Disk (Priority: P2)

**Goal**: Guarantee the on-disk output is a clean, navigable, externally-consumable knowledge base. Day folders are auto-rotated at midnight; filenames sort chronologically; rapid restarts never overwrite; an auto-generated `README.md` documents the layout for downstream LLM agents.

**Independent Test**: Run huske across two distinct local dates (or simulate via a clock-injecting fixture). Confirm: two `YYYY-MM-DD` subfolders exist, lexicographic sort of files within each = chronological order, frontmatter on a randomly picked file correctly identifies the day/time window, and stopping + restarting within the same second produces two distinct filenames (no overwrite). Open `README.md` at the output root and confirm it documents the layout.

### Tests for User Story 2

- [x] T030 [P] [US2] Add `tests/integration/test_cross_day.py`: with a clock fixture jumping from 23:50 to 00:10 next day, run a chunked session and assert two day folders exist, the boundary chunk lives in its **start-time** day folder per spec/contract, and the chunk metadata reflects the actual span
- [x] T031 [P] [US2] Add `tests/unit/test_paths_disambiguation.py`: simulate two sessions whose `start_time` is identical to the second; assert `transcript_filename` produces distinct paths because `sessionid8` differs (deterministic via fixture-injected RNG seeds)
- [x] T032 [P] [US2] Add `tests/unit/test_output_readme.py`: assert `ensure_output_readme(output_root)` is idempotent, rewrites only when missing or stale, and the rendered content matches `contracts/transcript-format.md` § "Auto-generated `README.md`"

### Implementation for User Story 2

- [x] T033 [P] [US2] Implement `ensure_output_readme(output_root: Path) -> None` in `huske/paths.py` (or a new `huske/output_readme.py`): writes `<output_root>/README.md` with the canonical layout doc from the contract; refreshes only if file is missing or content drifts from the canonical template
- [x] T034 [US2] Wire `ensure_output_readme` into `huske run` startup (after config validation, before lock acquisition) and into `huske recover` (so a recovery-only run also keeps the README current)
- [x] T035 [US2] Harden filename disambiguation in `huske/paths.py`: when `transcript_filename(chunk)` would collide with an existing file (concurrent-write race or extreme edge case), append `_<rand4hex>` before `.md` and log a warning. This is the last-resort guard on top of the sessionid-based scheme
- [x] T036 [US2] Verify cross-day rotation in `huske/chunker/rotator.py`: confirm chunks are filed under their `start_time`'s day folder regardless of when they close (a 23:55-started chunk closing at 00:10 stays in yesterday's folder); ensure new-day folder creation uses `paths.day_folder` lazily

**Checkpoint**: User Stories 1 AND 2 both work. The `<output_root>/` tree is now a self-describing, sort-clean, collision-free knowledge base. SC-003 and SC-004 are measurable.

---

## Phase 5: User Story 3 — Live Terminal UI Showing Recording Status (Priority: P3)

**Goal**: A Rich-powered live status display replaces the plain log output: large recording indicator, in-chunk elapsed + countdown, peak-level meters per channel, queue depth, last-saved transcript path, rolling event log, sticky warnings. Sleep/wake and device disconnects are detected and surfaced. `huske doctor` validates the full stack including a 3-second peak-level capture.

**Independent Test**: Start `huske run` and watch the terminal: the panel renders within 1 s, the countdown ticks down in real time, the peak-level meters move while you speak, and the "last saved" line updates after each rotation. Disconnect the microphone mid-session and confirm a non-fatal warning appears and the panel reflects the degraded state. Run `huske doctor` and confirm it prints the validation report and exits 0 on a healthy setup.

### Tests for User Story 3

- [x] T037 [P] [US3] Add `tests/unit/test_render_state.py`: assert `RenderState.update(...)` is thread-safe, event deque is capped at 5, and warnings are sticky (not auto-evicted by event rotation)
- [x] T038 [P] [US3] Add `tests/unit/test_sleep_wake.py`: simulate a 7-second gap in `last_callback_at` and assert the heartbeat monitor closes the current chunk with a `gap_seconds` annotation and attempts to restart the stream
- [x] T039 [P] [US3] Add `tests/integration/test_doctor.py`: run `huske doctor` against a mocked sounddevice with a healthy aggregate device → exit 0; with no input devices → exit 3 with the actionable BlackHole guidance from quickstart

### Implementation for User Story 3

- [x] T040 [P] [US3] Implement `RenderState` dataclass + thread-safe `update(**fields)` and `push_event(severity, message)` in `huske/ui/state.py` per `data-model.md` §5
- [x] T041 [P] [US3] Implement peak-level computation in `huske/capture/stream.py`: maintain a 1-second rolling max of |samples| per channel, expose `peak_levels_db()` for the UI; this runs in the audio callback so it must be allocation-free (preallocate the buffer)
- [x] T042 [US3] Implement Rich `Live` UI in `huske/ui/live.py`: build a `Layout` with `header` / `main` / `footer` regions per `research.md` R11; render at 8 Hz from `RenderState`; level bars use Rich's bar-graph or a custom `█▇▆▅▄▃▂▁` ramp; rolling event list color-codes `info`/`warn`/`error`
- [ ] T043 [US3] _(deferred to v0.2)_ Implement `q` / `?` keypress handling in `huske/ui/live.py`. **Status**: Ctrl+C / SIGTERM are wired and documented as the stop signal; raw-stdin keypress is a nice-to-have not shipped in v0.1.
- [x] T044 [US3] Wire `RenderState` updates from the run loop in `huske/cli.py`: chunker rotation → `update(current_chunk_seq=..., next_rotation_at=...)`; worker completion → `update(last_saved=..., queue_depth=...)`; capture-stream errors → `push_event("warn", ...)`; mount the Rich Live in the `huske run` command unless `--no-ui` is set
- [x] T045 [US3] Implement sleep/wake heartbeat monitor in `huske/session.py`: an asyncio task checks `capture.stream.last_callback_at` every 1 s; if `>5 s` stale, mark the current chunk with `gap_seconds = elapsed`, close it, submit for transcription, and restart the input stream; emit a `warn` event to `RenderState`
- [x] T046 [US3] Implement device-disconnect handling in `huske/capture/stream.py`: catch `sounddevice.PortAudioError` and degraded callback states; mutate the chunk's `audio_sources` (drop "microphone" or "system" if its channel goes flatline > 5 s); push a sticky warning to `RenderState` until the source recovers
- [x] T047 [US3] Implement `huske doctor` command in `huske/cli.py`: runs all checks from `contracts/cli.md` `huske doctor` section (Python version, faster-whisper importable, model cached, sounddevice working, default input is an aggregate device with 2ch+, 3-second sample with peak meter per channel, output/audio roots writable, no orphan sessions), prints the human-readable report (Rich-styled), supports `--json` for machine output, exits per the documented exit codes

**Checkpoint**: All three user stories are independently functional. SC-006 (first-run usability) is measurable.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Ship-readiness improvements that span all stories.

- [x] T048 [P] Implement `--no-ui` flag plumbing in `huske/cli.py`: when set, skip the Rich Live mount and route lifecycle events as INFO log lines to stdout (already JSON via structlog)
- [x] T049 [P] Implement `--keep-audio` flag plumbing: pass through to `RuntimeConfig`; transcription worker skips the post-success WAV deletion when set
- [x] T050 [P] Write project `README.md` at repo root: short pitch, install steps (linking to `specs/001-huske-recorder/quickstart.md`), `huske doctor` snippet, link to `contracts/transcript-format.md` for downstream-LLM consumers
- [x] T051 [P] Add `examples/config.toml` with the documented default values + comments
- [x] T052 [P] Add a small integration smoke-test `tests/integration/test_smoke.py` that runs `huske doctor --json` against the test fixtures and asserts a clean exit
- [x] T053 Run the manual quickstart validation per `specs/001-huske-recorder/quickstart.md` § "Validation against acceptance scenarios" — every US acceptance scenario must reproduce on a clean install before this branch ships

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)** has no dependencies — start immediately.
- **Foundational (Phase 2)** depends on Setup completion. **BLOCKS all user stories.**
- **User Story 1 (Phase 3)** depends on Foundational. Delivers the MVP.
- **User Story 2 (Phase 4)** depends on Foundational; logically lands after US1 because its tests assume the US1 pipeline is producing transcripts.
- **User Story 3 (Phase 5)** depends on Foundational; its UI consumes events emitted by US1's run loop, so practical implementation order is US1 → US3, but the UI layer is an additive overlay and could be developed against a stub in parallel.
- **Polish (Phase 6)** depends on all user stories.

### User Story Dependencies

- **US1 (P1)**: depends only on Foundational. Independently testable: produces transcripts on disk via `huske run`.
- **US2 (P2)**: depends on Foundational; integrates with US1 (its tests assume the US1 pipeline writes files). Independently testable: cross-day folder structure + README + collision-free filenames.
- **US3 (P3)**: depends on Foundational; integrates with US1 (UI surfaces events from the run loop). Independently testable: live UI renders, sleep/wake handled, doctor command passes.

### Within Each User Story

- Models / dataclasses before services that consume them.
- Pure-function modules (paths, writer, state) before the orchestration that wires them.
- Tests can be written alongside or before the unit they cover; the integration tests gate the story checkpoint.

### Parallel Opportunities

- All `[P]` Setup tasks (T003–T006) can run in parallel.
- All `[P]` Foundational tasks (T008–T010, T013–T014) can run in parallel after T007 lands the config model.
- Within US1: T015–T018 (test scaffolding + unit tests) and T021–T022, T024 (independent modules — chunker dataclass, capture stream, writer) can run in parallel. T023 (rotator) depends on T021 + T022. T025 (worker) depends on T024. T027 (CLI wire-up) depends on T022, T023, T025, T026. T029 must follow T022 + T023.
- Within US2: T030–T032 (tests) and T033 (README) are mutually parallel; T034 depends on T033 + T027; T035–T036 are independent edits.
- Within US3: T037–T039 (tests) and T040–T041 (state + level meters) are mutually parallel; T042 depends on T040; T043–T046 depend on T042; T047 (doctor) depends on T010 and is otherwise independent.
- Polish (Phase 6) tasks T048–T052 are all independent; T053 depends on every preceding task.

---

## Parallel Example: User Story 1

```bash
# After Foundational is done, US1 work that can run in parallel:
Task T015: "Add tests/integration/conftest.py fixtures (fake_audio_stream, tiny_model, ...)"
Task T016: "Add tests/unit/test_chunker.py covering rotation handoff"
Task T017: "Add tests/unit/test_writer.py covering frontmatter schema"
Task T018: "Add tests/unit/test_recovery.py covering orphan detection"
Task T021: "Implement AudioChunk dataclass in huske/chunker/__init__.py"
Task T022: "Implement audio capture stream in huske/capture/stream.py"
Task T024: "Implement transcript writer in huske/transcribe/writer.py"

# Then sequentially:
Task T023: "Implement chunker rotation in huske/chunker/rotator.py" (needs T021 + T022)
Task T025: "Implement transcription worker subprocess" (needs T024)
Task T026: "Implement orphan recovery scanner"
Task T027: "Wire huske run end-to-end" (needs T022, T023, T025, T026)
Task T028: "Implement huske recover command" (needs T026)
Task T029: "Add audio-source tagging" (needs T022 + T023)
Task T019: "Add end-to-end integration test" (needs T027)
Task T020: "Add graceful-stop integration test" (needs T027)
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Complete Phase 1 (Setup) — `pyproject.toml`, package skeleton, dev deps installed.
2. Complete Phase 2 (Foundational) — config, paths, logging, device validation, session shell, CLI shell.
3. Complete Phase 3 (US1) — capture, chunker, worker, writer, recovery, `huske run` + `huske recover` wired end-to-end.
4. **STOP and VALIDATE**: run the US1 independent test (record for 17 min, get two transcript files; SIGKILL + `huske recover`).
5. Ship as v0.1.0 — already valuable as a personal "always-on transcription" tool, even with plain log output and no live UI.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. Add US1 → MVP (v0.1.0).
3. Add US2 → polished knowledge base, README on disk, rapid-restart-safe (v0.2.0).
4. Add US3 → live UI + doctor command + sleep/wake handling (v0.3.0).
5. Polish → README, examples, smoke test, manual quickstart validation (v0.3.1).

### Parallel Team Strategy

With multiple developers post-Foundational:

- Developer A drives US1 (the critical path; longest phase).
- Developer B starts US3's UI scaffolding (T040–T042) against a stub `RenderState` while US1 is in flight; integrates with US1 (T044) once T027 lands.
- Developer C handles US2 + Polish (smaller surfaces) once US1's writer/paths are in place.

---

## Notes

- `[P]` = different file, no dependency on incomplete tasks.
- `[Story]` label maps tasks to spec stories for traceability.
- Each user story phase ends with a checkpoint that maps to spec acceptance scenarios.
- All file paths are absolute or repo-relative; `huske/` lives at the repository root.
- Avoid: cross-story dependencies that would prevent shipping US1 alone as MVP. Anything in US2 or US3 that breaks US1 is a refactor, not a feature.
