# Huske.app — the native macOS app

Huske.app is huske's UI. The engine itself is headless: the app supervises the
`huske` command-line engine and renders its control plane in a real window —
it never re-implements recording or transcription logic (see
`docs/adr/0006-native-macos-app.md` and
`docs/adr/0007-app-first-retire-the-tui.md`).

## What it does

- **Record** — start/stop/pause sessions with live microphone + system-audio
  level meters (peak hold), current chunk and elapsed time, transcription
  queue state, warnings, and a live activity feed. Toggle periodic
  screenshots and LLM distillation mid-session, and switch the microphone
  without restarting.
- **Attach** — if a session is already recording (started by `huske run` in a
  terminal or by the login LaunchAgent), the app finds its control socket and
  becomes a remote control for it.
- **Transcripts** — a day-grouped browser over `~/huske/transcripts` with
  per-run rendering (mic / system / echo badges and timestamps), full-text
  search, raw-Markdown view, Reveal in Finder, and open-in-editor.
- **Doctor** — runs `huske doctor --json` and renders every check with its
  fix-it hint, plus the input-device inventory.
- **Configuration** — edits `~/.config/huske/config.toml` through
  `huske config set`, so every change is validated by the engine itself.
  Explicitly-set keys are marked with an amber dot.
- **Menu bar extra** — recording state at a glance with quick actions; the
  window can be closed while recording continues.
- **Recovery** — streams `huske recover` output for orphaned chunks after a
  crash.

Quitting the app while it owns a recording performs the same graceful stop as
Ctrl+C in the terminal: the current chunk is finalized and pending
transcriptions drain before the process exits.

## Requirements

- macOS 14+ (Apple Silicon, same as the engine).
- The `huske` CLI installed — `uv tool install "huske[mcp]"` or
  `brew install tiagomoraes/huske/huske`. The app auto-detects it in
  `~/.local/bin`, Homebrew paths, and `PATH`; you can point it at a specific
  binary in the app's Settings (⌘,).

## Building

```bash
cd macos
swift test                # HuskeKit unit tests
./scripts/build-app.sh    # → macos/dist/Huske.app (ad-hoc signed)
open dist/Huske.app
```

The bundle version is stamped from `pyproject.toml` — the repo's single
source of truth. The app icon is generated from the brand mark at build time
and cached under `macos/.cache/`.

Development conveniences:

```bash
swift build && HUSKE_APP_DEMO=1 .build/debug/Huske   # scripted fake session, no engine
.build/debug/Huske --render-screens /tmp/screens     # offscreen PNGs of key screens
HUSKE_INTEROP_PYTHON=../.venv/bin/python swift test --filter PythonInterop
```

The last command runs the cross-language contract test: the Swift client
against the real Python `ControlServer`.

## Permissions

When the app starts a session, macOS attributes the microphone and
screen/audio-capture permission prompts to **Huske.app** (the engine runs as
its child). Approve both in System Settings → Privacy & Security the first
time. Sessions started from a terminal keep their existing terminal-level
grants.

## How it talks to the engine

```
Huske.app ──spawns──▶ huske run --no-ui --control-socket ~/…/huske/app-xxxx.sock
                      (--no-ui is a compat no-op on current engines — ADR 0007)
     ▲                        │
     └── JSON lines ◀─────────┘   state snapshots at ~8 Hz, commands upstream
```

The protocol is the same one the bundled menu bar helper uses
(`huske/ipc/protocol.py`), extended with richer state in v2. Attach mode
scans `~/Library/Application Support/huske/control-*.sock` for engine-owned
sessions. Transcripts, config, doctor, devices, and recovery go through the
documented `.md` contract and the `huske config show/set/unset`,
`huske doctor --json`, `huske devices --json`, and `huske recover` commands.
