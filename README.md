# huske

[![CI](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> *huske* — Norwegian for "to remember"

A native macOS app backed by a headless engine that continuously records your
microphone plus your computer's system audio, and transcribes the audio locally with
[Parakeet](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) on Apple
Silicon (MLX) — producing a day-organized, LLM-friendly knowledge base of
everything that was said on your machine throughout the day.

Point Claude Code (or any other LLM agent) at `~/huske/transcripts/` and ask
it about your day.

```text
~/huske/transcripts/
├── 2026-05-07/
│   ├── 091500_8a3f2c19_001.md
│   ├── 093000_8a3f2c19_002.md
│   └── 094500_8a3f2c19_003.md
└── README.md
```

## Features

- **Continuous capture** — mic (sounddevice) + system audio (Core Audio process tap
  on macOS 14.4+, ScreenCaptureKit fallback on older macOS), source-tagged and
  gapless at chunk boundaries.
- **No drivers, no Audio MIDI Setup** — system audio comes through Apple's
  built-in capture APIs. Grant the macOS audio/screen capture permission once.
- **Local transcription** — [Parakeet](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
  (`parakeet-tdt-0.6b-v3`) on the Apple Silicon GPU via MLX. It is multilingual
  (~25 languages) and, being a transducer, emits nothing on silence instead of
  hallucinating repeated filler the way Whisper does. Audio never leaves your
  machine. Parakeet *infers* the language per decode window and cannot be told
  which one, so if you speak a non-English language mixed with English jargon
  and need the transcript pinned to one language, use the Whisper engine, whose
  decoder takes a language token:
  `--asr-engine whisper --model large-v3-turbo --language pt`.
- **Speech-gated segmentation** — files split on real pauses in speech, not a
  fixed clock: a chunk opens when speech starts and closes after a pause
  (`--silence-split`, default 60 s) or at the `--chunk-minutes` cap (default
  15 min). Quiet stretches produce no file, and a conversation isn't cut
  mid-sentence at an arbitrary tick. `--no-speech-gated` restores fixed-interval
  rotation.
- **Speaker-bleed removal** — when you record mic + system on speakers (no
  headphones), the system audio bleeds into the mic and would be transcribed
  twice. huske handles it in two stages: coherence-based echo *suppression*
  attenuates the bleed in the mic audio before transcription (`--echo-cancel`,
  on by default; self-gating — no effect with headphones, and it can't touch
  your own voice), and a transcript-level dedup then *removes* any residual mic
  copy of a system line, including partial fragments (`--echo-dedup
  drop|annotate|off`). (True sample-precise cancellation isn't possible because
  the mic and system are captured on independent clocks — see the PR notes.)
- **Resilient** — graceful stop finalizes the partial chunk; SIGKILL + restart
  auto-recovers orphaned audio.
- **Native macOS app** — huske's face: live level meters, start/stop/pause,
  a ⌘K command palette, mid-session toggles, a transcript browser with search,
  a Doctor pane, an engine-validated settings editor, and open-at-login +
  record-on-open switches, plus a menu bar extra. It also attaches to sessions
  started from the terminal or at login. Built from source in `macos/`; see
  [docs/macos-app.md](docs/macos-app.md).
- **Headless engine** — `huske run` records with no UI chrome: plain progress
  lines on stdout and a macOS menu bar item for pause/screenshots/stop. Ideal
  under a LaunchAgent or over SSH. (The old Rich terminal panel was retired
  in favor of the app — see `docs/adr/0007-app-first-retire-the-tui.md`.)
- **LLM-ready output** — every transcript is a single Markdown file with full
  YAML frontmatter; the directory layout is documented in
  `~/huske/transcripts/README.md` (auto-generated).
- **Private GitHub sync (opt-in)** — Huske.app publishes each finished
  transcript to a private Git repository through your existing SSH/Git
  credentials. Git commits are the durable retry queue; Huske stores no cloud
  token and never syncs audio, screenshots, logs, or config.
- **Always-on MCP as a separate service** — `services/huske_mcp` runs on a
  Linux/VPS, pulls the repository, incrementally indexes it, and serves agents
  while the Mac sleeps. The default profile is designed for a 512 MB VPS;
  semantic hybrid search is an explicit larger-memory option.
- **LLM correction of transcripts (opt-in)** — a tiny local MLX model (or
  Ollama) fixes typos and obvious ASR errors in each finished transcript.
  The raw snapshot stays on-device as `.asr.txt`; Git sync publishes the
  polished Markdown.
- **Optional periodic screenshots** — opt in with `--screenshots` to also
  capture a JPEG of every attached display every 60 s (compressed for LLM input), stored under
  `~/huske/screenshots/YYYY-MM-DD/<session>/HHMMSS_dN.jpg` for downstream
  multimodal LLM use. Off by default; see [Periodic screenshots](#periodic-screenshots-opt-in).

## Requirements

- macOS 13 (Ventura) or newer. macOS 14.4+ is recommended for system audio
  capture that keeps working while another app is sharing your screen. Apple
  Silicon is the primary target.
- Python 3.11, 3.12, 3.13, or 3.14.

## Quickstart

```bash
# 1. Install
uv tool install huske

# 2. Validate setup (will prompt for macOS capture permission on first run)
huske doctor

# 3. Record (Ctrl+C to stop)
huske run

# 4. Reclaim orphans from a prior crash without recording
huske recover
```

Other install options:

```bash
# Alternative Python tool installer:
pipx install huske

# macOS Apple Silicon with Homebrew:
brew tap tiagomoraes/huske
brew install huske
```

On macOS 14.4+, Huske uses a Core Audio process tap for system audio so Google
Meet, Zoom, and similar screen sharing do not interrupt capture. macOS may
prompt for **Audio Capture** or a screen-recording-adjacent permission for your
Python interpreter or launcher. On older macOS versions, or when
`--system-audio-backend sck` is set, Huske falls back to ScreenCaptureKit, which
requires **Screen Recording** permission and can be interrupted by another app's
screen share. Run `huske doctor --system-audio-backend tap` if the system level
meter goes silent during screen sharing.

Runtime controls live in the app and the menu bar:

- **Huske.app** — pause/resume, screenshots, distillation, and microphone
  switching from the Record pane — or from anywhere via the ⌘K command
  palette.
- **Menu bar** — terminal and LaunchAgent sessions get a huske menu bar item
  with pause/resume, screenshots, distillation, and stop.
- **Ctrl+C** — graceful stop for terminal sessions (finalizes the current
  chunk and drains pending transcriptions).

Pausing finalizes the current partial chunk and stops writing audio until you
resume. Toggling screenshots takes effect immediately, using the configured
screenshots directory and interval. Toggling distillation flips it on or off for
the running session: turning it on checks that the local LLM daemon and model are
ready before it starts (and warns with a fix-it hint if they are not). On macOS
the same actions are available from the menu-bar dropdown. The toggle is
session-only — set `distill_enabled` in config to make it the default.

For prerelease builds or exact GitHub tags, install directly from the repository:

```bash
uv tool install "git+https://github.com/tiagomoraes/huske.git@v0.13.0"
```

See [quickstart.md](specs/001-huske-recorder/quickstart.md) for the full setup.

### Run on login (macOS)

The easiest way is in **Huske.app → Configuration → This app**: switch on
*Open Huske at login* and *Start recording when Huske opens* — your Mac
records from the moment you sign in, with the app as the UI.

Prefer no app at all? `huske autostart install` registers a per-user
[LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
that runs a headless `huske run` automatically every time you log in (the
menu bar item is then the only UI).

```bash
# Install — writes ~/Library/LaunchAgents/me.huske.plist and loads it now.
huske autostart install

# Optional: pass a config file or non-default log level.
huske autostart install --config ~/.config/huske/config.toml --log-level DEBUG

# Show current state (installed, loaded, pid, last exit code).
huske autostart status

# Manually start/stop without uninstalling (repeated stop is a no-op).
huske autostart start
huske autostart stop

# Remove entirely.
huske autostart uninstall
```

Restart policy is "restart on crash only" by default
(`KeepAlive={SuccessfulExit:false}`): if you `huske autostart stop` or huske
exits cleanly, it stays stopped until next login. Pass `--no-keep-alive` to
disable auto-restart on crash too.

**Permissions.** The first time the agent records, macOS will prompt for
**Microphone** and the relevant audio/screen capture permission for the
resolved `huske` binary (or its Python interpreter). Approve them in System
Settings → Privacy & Security. If the prompts don't appear after login, run
`huske autostart start` once from the terminal so they fire while you're
present.

**Logs.** The agent is headless; stdout and stderr are appended to:

```text
~/Library/Logs/huske/agent.out.log
~/Library/Logs/huske/agent.err.log
```

Tail those if you suspect the agent isn't recording. `huske doctor` also
reports the agent's state — installed, loaded, pid, and the error-log path if
it recently crashed — so you can check on it without a separate command.

`huske autostart` is macOS-only (it uses `launchd`); the commands exit with
a friendly error on other systems.

### Update notifications

On startup, huske checks PyPI at most once every 24 hours and prints an
"update available" banner with the right upgrade command for your install
method (`uv tool upgrade huske`, `pipx upgrade huske`, or
`brew upgrade huske`). The check runs in a background thread, is silent on
network errors, on non-TTY stderr, and for editable installs. Disable it with:

```bash
export HUSKE_NO_UPDATE_CHECK=1
```

### Periodic screenshots (opt-in)

`huske run --screenshots` enables a background thread that captures a JPEG of
every attached display every 60 seconds (configurable). Screenshots are
written to:

```text
~/huske/screenshots/YYYY-MM-DD/<session_id>/HHMMSS_dN.jpg
```

…where `dN` is the display index (`d1` is the main display). Filenames are
timestamped so a downstream multimodal LLM can correlate each screenshot
with that day's transcripts.

Capture uses macOS's built-in `screencapture`, so no extra dependency is
needed. It uses Screen Recording permission; if system audio is using the Core
Audio tap, macOS may prompt for this separately when screenshots are first
enabled.

Each capture is then shrunk in place with macOS's built-in `sips`: downscaled so
its long edge is at most 1568 px (the resolution Claude's vision API targets;
never upscaled) and re-encoded at JPEG quality 60 — small to store and ideal as
LLM input. Tune with `--screenshot-max-dimension` (0 disables resize) and
`--screenshot-quality`; if `sips` isn't on the PATH the full-size capture is kept.

Flags:

```bash
huske run --screenshots                       # opt in
huske run --screenshots --screenshot-interval 30
huske run --screenshots --screenshot-quality 50 --screenshot-max-dimension 1024
huske run --screenshots --screenshots-root ~/another/path
```

The screenshot interval must be at least 1 second.

> **Privacy.** Screenshots can capture passwords, private chats, financial
> details, and anything else on screen. They're stored unencrypted on disk
> and read-accessible to any process running as your user. Treat
> `~/huske/screenshots/` exactly like the audio and transcript directories:
> never commit it, share with care, and review the
> [Privacy and consent](#privacy-and-consent) section before enabling.

## Sync transcripts and query them from agents (opt-in)

The recording app does not host MCP. Open **Cloud sync** in Huske.app, create a
private GitHub repository, paste its SSH URL, and press **Sync now**. After the
first push succeeds, enable automatic sync.

Terminal equivalent:

```bash
huske config set sync_remote git@github.com:you/huske-transcripts.git
huske config set sync_enabled true
huske sync
```

Huske publishes only canonical transcript Markdown under
`transcripts/YYYY-MM-DD/*.md`. Git uses your existing SSH agent or credential
helper; Huske stores no GitHub token. Audio, screenshots, logs, config, and
credentials are never copied.

Run the independent `services/huske_mcp` package on an always-on Linux/VPS
host. It pulls the private repository, incrementally indexes it into SQLite, and
serves a permanent authenticated Streamable-HTTP MCP endpoint with `overview`,
`recap`, `search`, `fetch`, and `sync_status`.

The default `tiny` profile is designed for 1 vCPU / 512 MB: one process, one
poll thread, FTS5, an 8 MB SQLite cache, and no resident model. The optional
`semantic` profile adds real hybrid Model2Vec retrieval and needs more memory
(at least 1 GB for the default multilingual model).

Polling is the consistency mechanism; a signed GitHub webhook can wake it early.
This heals missed webhooks and restarts without a second data plane. Full setup:
**[docs/server.md](docs/server.md)**. Client wiring:
**[docs/integrations.md](docs/integrations.md)**. Decision record:
[ADR 0009](docs/adr/0009-git-replica-and-isolated-mcp-service.md).

## Correct transcript typos (opt-in)

Huske can polish each finished transcript with a tiny local MLX model (default
Qwen3.5 0.8B) or Ollama. The job is conservative ASR correction, not
summarisation. The raw snapshot is kept as `<name>.asr.txt`; the canonical
`.md` is what syncs and what the VPS service indexes.

```bash
huske distill
```

To correct automatically after each chunk:

```toml
distill_enabled = true
distill_model = "mlx-community/Qwen3.5-0.8B-4bit"
```

Correction runs off the recording hot path and failures never block recording
or cloud sync. See [docs/distillation.md](docs/distillation.md).

## Privacy and consent

huske is local-first: audio capture and transcription run on your machine, and
the app writes transcripts to your configured filesystem path. That does not
make the data low-risk. Recordings, transcripts, logs, filenames, and device
metadata can contain private or legally sensitive information.

- Get consent before recording other people or regulated conversations.
- Do not commit generated audio, transcripts, logs, local configs, model caches,
  or screenshots containing private content.
- If you enable cloud sync (`sync_enabled`), plaintext transcripts are copied
  to the private Git repository you configured. Restrict repository access,
  enable strong GitHub account security, and treat its history as sensitive.
- The VPS replica also holds plaintext transcript history. Keep `huske-mcp` on
  loopback or a private overlay, terminate TLS at the proxy, require its bearer
  token, and enable disk encryption on the host.
- If you run `huske export` and sync that folder to a third-party cloud (Drive,
  Dropbox, iCloud), plaintext transcripts are stored there under that provider's
  retention and scanning policy. Prefer `--statements-only` if you do.
- If you enable distillation (`distill_enabled`), transcript text is sent to the
  configured local model backend. The default MLX backend runs as a child process
  on your Mac; Ollama is an optional loopback backend. Pointing an endpoint at a
  remote daemon changes that privacy boundary.
- The `--screenshots` flag captures everything visible on every attached
  display every 60 s — including any password manager popovers, banking
  tabs, or private DMs that happen to be open. Leave it off unless you've
  consciously decided you want this in the on-disk record.
- Redact `huske doctor` output before sharing it publicly.
- Report security or privacy vulnerabilities privately through
  [SECURITY.md](SECURITY.md).

## Documentation

- [Development](docs/development.md) — local setup, checks, and test strategy.
- [Contributing](CONTRIBUTING.md) — how to open issues and pull requests.
- [Issue triage](docs/issue-triage.md) — labels and maintainer workflow.
- [Release checklist](docs/releasing.md) — release preparation notes.
- [Spec](specs/001-huske-recorder/spec.md) — what huske does and why.
- [Plan](specs/001-huske-recorder/plan.md) — technical context and architecture.
- [CLI contract](specs/001-huske-recorder/contracts/cli.md) — flags, exit codes.
- [Transcript format contract](specs/001-huske-recorder/contracts/transcript-format.md) — the LLM-consumer interface.
- [Quickstart](specs/001-huske-recorder/quickstart.md) — end-to-end setup.
- [Glossary](CONTEXT.md) — domain language (Chunk, Segment, Passage, …).
- [LLM integrations](docs/integrations.md) — get huske context into Claude,
  ChatGPT, Claude Code, and hosted agents, from any device.
- [macOS app](docs/macos-app.md) — the native SwiftUI app over the same engine.
- [Always-on service](docs/server.md) — GitHub sync plus the isolated VPS MCP
  service (opt-in).
- [Transcript correction](docs/distillation.md) — polish ASR typos with a
  tiny local LLM (opt-in).
- [Architecture decisions](docs/adr/) — including the Git replica and isolated
  MCP service boundary in ADR 0009.

## Community

- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Use issue templates for bugs, features, and documentation reports.
- Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) and include
  the exact checks you ran.
- For help, see [SUPPORT.md](SUPPORT.md).

## License

huske is released under the [MIT License](LICENSE). Third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
