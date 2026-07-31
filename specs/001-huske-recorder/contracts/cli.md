# Contract: CLI Surface

**Status**: Current public CLI contract for v0.5.x
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
huske devices [OPTIONS]      List microphone input devices.
huske config <verb>          Inspect and edit ~/.config/huske/config.toml.
huske autostart <verb>       Manage the macOS LaunchAgent that runs huske on login.
huske distill [OPTIONS]      Distil transcripts into statement sidecars with a local LLM.
huske export [OPTIONS]       Write one Markdown digest per day for file-reading tools.
huske sync [OPTIONS]         Publish transcripts to the configured Git repository.
huske --version              Print version and exit.
huske --help                 Print help.
```

`huske` with no arguments is equivalent to `huske run`.

---

## `huske run`

**Purpose**: Start an always-on, headless recording session. Blocks the terminal, printing plain progress lines, until Ctrl+C. Interactive control lives in Huske.app (over `--control-socket`) and the macOS menu bar helper.

**Options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--chunk-minutes` `-c` | float (0.1–60) | `15` | Chunk duration. |
| `--output-root` | path | `~/huske/transcripts` | Where transcripts are written. |
| `--audio-root` | path | `~/huske/audio` | Where transient audio chunks are written. |
| `--model` | choice | `base` | `tiny` \| `base` \| `small` \| `medium` \| `large-v3`. |
| `--compute-type` | choice | `int8` | `int8` \| `int8_float16` \| `float16` \| `float32`. |
| `--device` | choice | `auto` | `auto` \| `cpu` \| `cuda`. |
| `--language` | str | (auto) | ISO 639-1, e.g., `pt`, `en`. |
| `--input-device` | str | (system default) | Microphone device name (substring match). If configured but unavailable, Huske falls back to the default input with a warning. System audio is independent of this flag. |
| `--keep-audio` / `--no-keep-audio` | bool | `--no-keep-audio` | Retain audio after transcription (compressed per `--keep-audio-format`). |
| `--keep-audio-format` | choice | `opus` | Kept-audio format: `opus` (lossy, smallest), `flac` (lossless), or `wav`. |
| `--screenshots` / `--no-screenshots` | bool | config/default false | Capture periodic screenshots. |
| `--screenshot-interval` | float (1–3600) | `60.0` | Seconds between screenshots. |
| `--screenshot-max-dimension` | int (0–10000) | `1568` | Downscale each screenshot's long edge to ≤ N px (0 disables; never upscales). |
| `--screenshot-quality` | int (1–100) | `60` | JPEG quality for screenshots. |
| `--screenshots-root` | path | `~/huske/screenshots` | Where screenshots are written. |
| `--config` | path | `~/.config/huske/config.toml` | Path to TOML config file (silently ignored if absent). |
| `--log-level` | choice | `INFO` | `DEBUG` \| `INFO` \| `WARNING` \| `ERROR`. |
| `--no-ui` | bool | `false` | Deprecated hidden no-op (the Rich live UI was removed — ADR 0007). Accepted so older launchers keep working. |
| `--menu-bar` / `--no-menu-bar` | bool | config/default true | Show the macOS menu bar helper while recording. |
| `--system-audio-backend` | choice | `auto` | `auto` \| `tap` \| `sck` \| `off`. `auto` uses Core Audio process tap on macOS 14.4+ and ScreenCaptureKit fallback otherwise. |

**Behavior**:

1. Validate config (Pydantic). On failure → exit code 2, error printed to stderr.
2. Run startup recovery (same as `huske recover` but in-process, blocking). Any orphans are queued before the new session starts.
3. Validate audio devices (same checks as `huske doctor`). If no usable input → exit code 3, actionable message.
4. Create session id, lock file, audio root directory.
5. Open audio stream, start chunk timer, publish control-plane state (~8 Hz when a socket is up).
6. On Ctrl+C / SIGTERM / a `stop` control command: enter `stopping` state, finalize current chunk, drain transcription queue, remove lock, exit 0.
7. On unrecoverable error: write final state to log, attempt to finalize current chunk, exit non-zero.

**Exit codes**:

| Code | Meaning |
|---|---|
| `0` | Graceful shutdown, all chunks transcribed. |
| `1` | Unexpected runtime error. |
| `2` | Config validation error. |
| `3` | Audio device validation error. |
| `4` | Transcription worker failed to initialize. |
| `130` | Interrupted (SIGINT) before initialization completed. |

**stdout/stderr**:
- Plain progress lines plus structured one-line-per-event console logs to stdout.
- Errors → stderr.

**Runtime controls**: Ctrl+C → graceful stop. Pause/resume, screenshots,
distillation, and device switching are driven over the control socket —
from Huske.app or the menu bar helper (`huske/ipc/protocol.py`).

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
huske doctor  v0.5.0

  ✓ Python             3.11.7
  ✓ huske version      0.5.0
  ✓ mlx-whisper        0.4.3
  ✓ model              'base' will be downloaded on first use if missing
  ✓ sounddevice        1 host API(s) detected
  ✓ microphone         'MacBook Pro Microphone' (1ch, 48000 Hz)
  ✓ mic sample         peak -2.3 dB (audible)
  ✓ system backend     auto -> Core Audio tap
  ✓ system audio       Core Audio process tap usable
  ✓ output root        writable: /Users/you/huske/transcripts
  ✓ audio root         writable: /Users/you/huske/audio

All checks passed.
```

If a check fails, the line shows an actionable hint (for example granting Audio Capture / Screen Recording permission or choosing an available microphone) and the command exits with a non-zero code.

**Options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--input-device` | str | (system default) | Device to validate. |
| `--system-audio-backend` | choice | config/default `auto` | Backend to validate: `auto`, `tap`, `sck`, or `off`. |
| `--config` | path | `~/.config/huske/config.toml` | |
| `--json` | bool | `false` | Emit machine-readable output instead. |

**Exit codes**: `0` all pass, `3` no usable microphone, `2` config error, `1` another non-fatal check failed.

---

## `huske autostart`

**Purpose**: Manage a per-user macOS [LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
(`~/Library/LaunchAgents/me.huske.plist`, label `me.huske`) that runs
a headless `huske run` automatically every time the user logs in. macOS-only;
exits with code `2` and a friendly error on other platforms.

**Verbs**:

```text
huske autostart install [OPTIONS]   Write the plist and load it via launchctl bootstrap.
huske autostart uninstall           Bootout and remove the plist.
huske autostart status              Print install/load/pid state. Exit 0 if loaded, 1 otherwise.
huske autostart start               launchctl kickstart (no-op if already running).
huske autostart stop                launchctl kill TERM (no-op if already stopped).
```

**`install` options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--config` | path | (none) | Path to a `config.toml` passed through to `huske run`. |
| `--log-level` | choice | `INFO` | Log level for the agent process. |
| `--keep-alive` / `--no-keep-alive` | bool | `--keep-alive` | When on, launchd restarts huske only on a non-zero exit (`KeepAlive={SuccessfulExit:false}`). |
| `--force` | bool | `false` | Overwrite an existing plist. |

**Logs**: the agent is headless; stdout/stderr are appended to
`~/Library/Logs/huske/agent.{out,err}.log`.

**Permissions**: the first time the agent records, macOS will prompt for
Microphone and the relevant audio/screen capture permission for the resolved `huske` binary
(or its Python interpreter). If the prompts don't appear after login, run
`huske autostart start` once from the terminal to fire them while a user
session is attached.

**Exit codes**:

| Code | Meaning |
|---|---|
| `0` | Command succeeded. `status` returns 0 only when the agent is installed AND loaded. |
| `1` | `launchctl` returned non-zero, plist already exists (without `--force`), or `status` reports not-installed/not-loaded. |
| `2` | Not running on macOS. |

---

## `huske sync`

**Purpose**: Incrementally publish canonical transcript Markdown to the private
Git repository configured by `sync_remote`. The managed checkout lives at
`sync_root`; Git commits are the durable retry queue.

**Options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--config` | path | `~/.config/huske/config.toml` | Config file. |
| `--force` | bool | `false` | Re-scan all canonical transcripts before publishing. |

**Behavior**:

1. Clone or fetch `sync_remote` using the user's existing SSH agent or Git
   credential helper.
2. Copy only `output_root/YYYY-MM-DD/*.md` into
   `transcripts/YYYY-MM-DD/*.md`.
3. Refuse to overwrite a remote path with different transcript bytes.
4. Commit new files, rebase on the remote branch, and push.

Audio, screenshots, statement sidecars, logs, config, and credentials never
enter the repository.

**Exit codes**: `0` synchronized or already current, `1` Git/publish failure,
`2` invalid config.

---

## `huske export`

**Purpose**: Write one Markdown file per day under `export_root`, for tools that
read files rather than speaking MCP. Incremental (a day is skipped when its
transcripts and statement sidecars are both unchanged) and atomic.

**Options**:

| Flag | Type | Default | Description |
|---|---|---|---|
| `--export-root` | path | `~/huske/export` | Where day files are written. |
| `--statements-only` | bool | `false` | Emit only distilled key points, omitting verbatim text. |
| `--since` | str | (all) | Only export days on or after this `YYYY-MM-DD`. |
| `--force` | bool | `false` | Rewrite days whose source content is unchanged. |
| `--output-root` | path | `~/huske/transcripts` | Transcript source. |
| `--config` | path | `~/.config/huske/config.toml` | |

**Exit codes**: `0` success, `1` no transcripts or a day failed to write, `2`
config error.

---

## Config file format

Path: `~/.config/huske/config.toml` (override with `--config`). Optional. Same field names as CLI flags but underscore-separated, with `chunk_minutes` instead of `--chunk-minutes`.

```toml
chunk_minutes = 15
output_root = "~/huske/transcripts"
audio_root = "~/huske/audio"
model = "base"
compute_type = "int8"
language = "pt"
keep_audio = false
keep_audio_format = "opus"
input_device = "MacBook Pro Microphone"
system_audio_backend = "auto"
log_level = "INFO"
sync_enabled = true
sync_remote = "git@github.com:you/huske-transcripts.git"
sync_branch = "main"
```

CLI flags always win over config file values.

---

## Stability guarantees for v1

- Command names (`run`, `recover`, `doctor`, `autostart`, `distill`, `export`,
  `sync`) and exit codes are stable.
- Flag names will not be renamed in v1.x; new flags may be added.
- Config TOML key names are stable; unknown keys are rejected as config errors.
- The transcript file format is governed by `transcript-format.md` and is the primary interface for downstream LLM consumers.
