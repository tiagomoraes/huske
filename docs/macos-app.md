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
- **Cloud sync** — configures a private Git repository, branch, and automatic
  transcript publishing without requiring a terminal. “Sync now” invokes the
  same `huske sync` path used by the recording engine. The pane also links to
  the separate `huske-mcp` VPS deployment guide; the app never starts an MCP
  server itself.
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
- The `huske` CLI installed — `uv tool install huske` or
  `brew install tiagomoraes/huske/huske`. The app auto-detects it and picks the
  newest one it finds; see [Which engine the app drives](#which-engine-the-app-drives).

## Which engine the app drives

A Mac accumulates `huske` installs — a `uv tool`, a Homebrew keg, a checkout's
virtualenv — and they upgrade on different days. The app drives exactly one:

- **Auto-detect (default)** — the *newest* engine among `~/.local/bin`,
  `/opt/homebrew/bin`, `/usr/local/bin`, and `PATH`. Newest by parsed version,
  never by string: `0.9.0` does not sort above `0.11.0`.
- **Pinned** — Settings (⌘,) → *huske engine* → **Choose…**, or **Use** beside
  any engine the app found. A pin is never second-guessed; **Auto-detect**
  drops it.

Settings lists every engine found, with its version and origin and which one is
in use — so "why is Huske running a version I already upgraded past?" has an
answer on screen instead of in a terminal.

### When the engine is not usable

Three situations, told apart because they need different fixes:

| Screen | What it means | What ends it |
| --- | --- | --- |
| *Welcome to huske* | no `huske` anywhere on this Mac | install with uv or Homebrew — one click when either is already present |
| *Huske can't run this engine* | the selected binary will not execute. Usually a checkout whose virtualenv was rebuilt: the console script survives, its `#!` interpreter does not | switch to another installed engine, drop the pin, or rebuild the checkout |
| *Your huske engine needs an update* | it runs, and predates `--control-socket` | upgrade with the package manager that owns *that* engine |

The upgrade button appears only when a package manager actually owns the engine
in use. It used to appear regardless, so `uv tool upgrade huske` was offered for
engines uv had never seen — the command exits 0 having upgraded a *different*
install, and the screen the user was staring at never changed. An engine that
cannot execute now says so, names the missing interpreter, and offers the
working engines sitting next to it.

## Updates

- **The app** — *Huske → Check for Updates…*, plus a once-a-day background
  check that puts a quiet `Update vX.Y.Z` chip under the nav rail, linking to
  the release. It asks GitHub for one release's version number and sends
  nothing else. Switch it off in Settings → *Updates*, or set
  `HUSKE_NO_UPDATE_CHECK=1` to silence the app and the engine's PyPI banner
  together.
- **The engine** — upgraded by whichever manager installed it
  (`uv tool upgrade huske`, `brew upgrade huske`). The app runs that command
  for you when it owns the engine in use.

App and engine version independently, and that is fine: the app feature-probes
whatever engine it finds, so a newer app with an older engine degrades to a
clear message instead of a broken session.

## Building

```bash
cd macos
swift test                # HuskeKit unit tests
./scripts/build-app.sh    # → macos/dist/Huske.app (signed; ad-hoc without a cert)
open dist/Huske.app
```

The bundle version is stamped from `pyproject.toml` — the repo's single
source of truth. The app icon is generated from the brand mark at build time
and cached under `macos/.cache/`.

The script signs with a `Developer ID Application` identity when one is in the
keychain and ad-hoc otherwise, so a contributor without a certificate still
gets a working build. Both paths apply the hardened runtime and
`macos/Huske.entitlements` — the microphone entitlement is only load-bearing
under the hardened runtime, and without it TCC denies the engine's mic access
*without prompting*. Releases are notarized on top of that
(`macos/scripts/notarize-app.sh`); see
[ADR 0010](adr/0010-developer-id-signing-and-notarization.md) and
[releasing.md](releasing.md).

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
