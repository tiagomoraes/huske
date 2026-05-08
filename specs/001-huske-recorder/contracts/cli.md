# Contract: CLI Surface

**Status**: Phase 1 design — frozen for v1
**Source**: `spec.md` FR-006, FR-013, FR-019, FR-021; `research.md` R10

This contract defines the public command-line surface of `huske`. Anything not listed here is internal and may change.

---

## Binary entry point

Installed as `huske` via `pyproject.toml` `[project.scripts]`. Also accessible as `python -m huske`.

---

## Top-level commands

```text
huske run [OPTIONS]          Start a recording session (default if no subcommand).
huske recover [OPTIONS]      Process orphaned audio from prior runs without recording.
huske doctor [OPTIONS]       Diagnose audio device + model setup; exit non-zero on failure.
huske --version              Print version and exit.
huske --help                 Print help.
```

`huske` with no arguments is equivalent to `huske run`.

---

## `huske run`

**Purpose**: Start an always-on recording session. Blocks the terminal with the live UI until the user issues Ctrl+C or `q`.

**Options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--chunk-minutes` `-c` | int (1–60) | `15` | Chunk duration. |
| `--output-root` | path | `~/huske/transcripts` | Where transcripts are written. |
| `--audio-root` | path | `~/huske/audio` | Where transient audio chunks are written. |
| `--model` | choice | `base` | `tiny` \| `base` \| `small` \| `medium` \| `large-v3`. |
| `--compute-type` | choice | `int8` | `int8` \| `int8_float16` \| `float16` \| `float32`. |
| `--device` | choice | `auto` | `auto` \| `cpu` \| `cuda`. |
| `--language` | str | (auto) | ISO 639-1, e.g., `pt`, `en`. |
| `--input-device` | str | (system default) | Microphone device name (substring match). System audio is always captured via ScreenCaptureKit and is independent of this flag. |
| `--keep-audio` / `--no-keep-audio` | bool | `--no-keep-audio` | Retain raw WAVs after transcription. |
| `--config` | path | `~/.config/huske/config.toml` | Path to TOML config file (silently ignored if absent). |
| `--log-level` | choice | `INFO` | `DEBUG` \| `INFO` \| `WARNING` \| `ERROR`. |
| `--no-ui` | bool | `false` | Run without the Rich live UI; emit log lines only. |

**Behavior**:

1. Validate config (Pydantic). On failure → exit code 2, error printed to stderr.
2. Run startup recovery (same as `huske recover` but in-process, blocking). Any orphans are queued before the new session starts.
3. Validate audio devices (same checks as `huske doctor`). If no usable input → exit code 3, actionable message.
4. Create session id, lock file, audio root directory.
5. Open audio stream, start chunk timer, render UI.
6. On Ctrl+C / `q` keypress: enter `stopping` state, finalize current chunk, drain transcription queue, remove lock, exit 0.
7. On unrecoverable error: write final state to log, attempt to finalize current chunk, exit non-zero.

**Exit codes**:

| Code | Meaning |
|---|---|
| `0` | Graceful shutdown, all chunks transcribed. |
| `1` | Unexpected runtime error. |
| `2` | Config validation error. |
| `3` | Audio device validation error. |
| `4` | Permission error (mic, screen recording, filesystem). |
| `130` | Interrupted (SIGINT) before initialization completed. |

**stdout/stderr**:
- With UI (default): UI renders to stdout via Rich. No human-readable lines outside the UI.
- `--no-ui`: structured one-line-per-event JSON logs to stdout.
- Errors → stderr in both modes.

**Keyboard shortcuts** (UI mode only):
- Ctrl+C → graceful stop.
- `?` → show or hide the controls overlay.
- Inside the controls overlay, `q` → graceful stop.
- Inside the controls overlay, `p` → pause or resume audio recording. Pausing finalizes the current partial
  chunk and does not write audio while paused.
- Inside the controls overlay, `s` → enable or disable periodic screenshots without restarting.
- Inside the controls overlay, Esc → close controls.

---

## `huske recover`

**Purpose**: Re-run only the recovery step (FR-023) without starting a new recording. Useful if the user wants to re-process audio without immediately resuming capture.

**Options**: subset of `run` — all `--audio-root`, `--output-root`, `--model`, `--compute-type`, `--device`, `--language`, `--config`, `--log-level`.

**Behavior**:

1. Scan `~/huske/audio/` for session directories whose lock file points at a dead PID (or whose lock file is absent but the directory still has WAVs).
2. For each orphan session:
   - For each WAV: verify integrity. Valid → enqueue for transcription. Invalid/truncated → move to `~/huske/audio/incomplete/<session_id>/` and log.
   - When all chunks processed: delete the empty session directory.
3. Print summary: `<n> sessions recovered, <m> chunks transcribed, <k> chunks moved to incomplete`.

**Exit codes**:

| Code | Meaning |
|---|---|
| `0` | All recoverable chunks transcribed; any unrecoverable ones moved to `incomplete/`. |
| `1` | Recovery aborted with errors. |
| `2` | Config validation error. |

---

## `huske doctor`

**Purpose**: Validate setup before recording. Always safe to run.

**Output** (human-readable; with `--json`, structured):

```text
huske doctor  v0.1.0

  ✓ Python             3.11.7
  ✓ huske version      0.1.0
  ✓ faster-whisper     1.2.1
  ✓ model              'base' will be downloaded on first use if missing
  ✓ sounddevice        1 host API(s) detected
  ✓ microphone         'MacBook Pro Microphone' (1ch, 48000 Hz)
  ✓ mic sample         peak -2.3 dB (audible)
  ✓ system audio       Screen Recording permission granted — ScreenCaptureKit usable
  ✓ output root        writable: /Users/you/huske/transcripts
  ✓ audio root         writable: /Users/you/huske/audio

All checks passed.
```

If a check fails, the line shows an actionable hint (e.g., for missing Screen Recording permission: "Open System Settings → Privacy & Security → Screen Recording, enable Python, then restart huske.") and the command exits with a non-zero code.

**Options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--input-device` | str | (system default) | Device to validate. |
| `--config` | path | `~/.config/huske/config.toml` | |
| `--json` | bool | `false` | Emit machine-readable output instead. |

**Exit codes**: `0` all pass, `3` device problem, `5` model unavailable, `2` config error.

---

## Config file format

Path: `~/.config/huske/config.toml` (override with `--config`). Optional. Same field names as CLI flags but underscore-separated, with `chunk_minutes` instead of `--chunk-minutes`.

```toml
chunk_minutes = 15
output_root = "~/huske/transcripts"
model = "base"
compute_type = "int8"
language = "pt"
keep_audio = false
input_device = "MacBook Pro Microphone"
log_level = "INFO"
```

CLI flags always win over config file values.

---

## Stability guarantees for v1

- Command names (`run`, `recover`, `doctor`) and exit codes are stable.
- Flag names will not be renamed in v1.x; new flags may be added.
- Config TOML key names are stable; unknown keys produce a warning, not an error.
- The transcript file format is governed by `transcript-format.md` and is the primary interface for downstream LLM consumers.
