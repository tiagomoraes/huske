# huske

[![CI](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> *huske* — Norwegian for "to remember"

A terminal app that runs in the background, continuously records your microphone
plus your computer's system audio, and transcribes the audio locally with
[mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) —
producing a day-organized, LLM-friendly knowledge base of everything that was
said on your machine throughout the day.

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
- **Local transcription** — `mlx-whisper`, default `base` model, runs on the
  Apple Silicon GPU via MLX. Audio never leaves your machine.
- **Configurable chunk size** — default 15 minutes, anything from 6 s to 60 min.
- **Resilient** — graceful stop finalizes the partial chunk; SIGKILL + restart
  auto-recovers orphaned audio.
- **Pretty terminal UI** — Rich Live panel with countdown, mic + system level
  meters, queue depth, last-saved transcript, rolling event log, and runtime
  controls for pause/resume and screenshots.
- **LLM-ready output** — every transcript is a single Markdown file with full
  YAML frontmatter; the directory layout is documented in
  `~/huske/transcripts/README.md` (auto-generated).
- **Local semantic search (opt-in MCP server)** — `huske[mcp]` adds on-device
  embedding + a local vector index so Claude Code, Claude Desktop, or ChatGPT
  can search your transcripts by meaning. Embeddings and the index never leave
  your machine; see [Search your transcripts from Claude / ChatGPT](#search-your-transcripts-from-claude--chatgpt-opt-in).
- **Optional periodic screenshots** — opt in with `--screenshots` to also
  capture a JPEG of every attached display every 10 s, stored under
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

Runtime controls in the live UI:

```text
?       open or close the controls overlay

Inside controls:
p       pause or resume audio recording
s       enable or disable periodic screenshots
i       choose microphone input device
q       graceful stop
Esc     close controls

Ctrl+C  graceful stop from anywhere
```

Pausing finalizes the current partial chunk and stops writing audio until you
resume. Toggling screenshots takes effect immediately, using the configured
screenshots directory and interval.

For prerelease builds or exact GitHub tags, install directly from the repository:

```bash
uv tool install "git+https://github.com/tiagomoraes/huske.git@v0.5.0"
```

See [quickstart.md](specs/001-huske-recorder/quickstart.md) for the full setup.

### Run on login (macOS)

`huske autostart install` registers a per-user
[LaunchAgent](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
that runs `huske run --no-ui` automatically every time you log in.

```bash
# Install — writes ~/Library/LaunchAgents/me.huske.plist and loads it now.
huske autostart install

# Optional: pass a config file or non-default log level.
huske autostart install --config ~/.config/huske/config.toml --log-level DEBUG

# Show current state (installed, loaded, pid, last exit code).
huske autostart status

# Manually start/stop without uninstalling.
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

**Logs.** The agent has no TUI; stdout and stderr are appended to:

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
every attached display every 10 seconds (configurable). Screenshots are
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

Flags:

```bash
huske run --screenshots                       # opt in
huske run --screenshots --screenshot-interval 30
huske run --screenshots --screenshots-root ~/another/path
```

The screenshot interval must be at least 1 second.

> **Privacy.** Screenshots can capture passwords, private chats, financial
> details, and anything else on screen. They're stored unencrypted on disk
> and read-accessible to any process running as your user. Treat
> `~/huske/screenshots/` exactly like the audio and transcript directories:
> never commit it, share with care, and review the
> [Privacy and consent](#privacy-and-consent) section before enabling.

## Search your transcripts from Claude / ChatGPT (opt-in)

The base install gives any LLM agent file access to `~/huske/transcripts/`. For
*semantic* search — "what did we decide about the pricing model last week?"
across months of calls — install the optional extra:

```bash
pip install 'huske[mcp]'   # mlx-embeddings + sqlite-vec + the MCP SDK
```

This adds two subcommands and one config flag:

1. **Build the index.** `huske index` embeds every transcript under
   `output_root` into a single local vector file (`~/huske/index/passages.db`)
   using a multilingual model that runs on the Apple Silicon GPU via MLX —
   the same Metal stack `mlx-whisper` already uses. Nothing leaves your machine.

   ```bash
   huske index                 # backfill your whole history (incremental)
   huske index --rebuild       # after changing the embedding model
   huske index --fast          # full speed (skip the default low-impact throttle)
   ```

   The backfill runs **low-impact by default** — it lowers its CPU priority,
   shrinks the embed batch, and releases the MLX buffer cache between files so a
   full-history backfill won't exhaust RAM or pin the GPU. It's a bit slower but
   stays out of your way; pass `--fast` (or set `index_low_impact = false`) when
   you'd rather it finish quickly. For finer control, tune `embed_batch_size` and
   `index_memory_limit_mb` in `~/.config/huske/config.toml`.

   To keep the index fresh automatically, set `indexing_enabled = true` in
   `~/.config/huske/config.toml`; `huske run` then embeds each finalized
   transcript in the background, in an isolated subprocess that never blocks
   audio capture.

2. **Serve it over MCP.** `huske mcp` runs a small always-on HTTP server
   (loopback-only, guarded by an auto-generated bearer token and Origin/Host
   validation) that exposes `search` and `fetch` tools.

   ```bash
   huske mcp
   # prints the endpoint, token, and a ready-to-paste registration command
   ```

   **Claude Code / Claude Desktop** connect directly — no tunnel:

   ```bash
   claude mcp add --transport http huske http://127.0.0.1:7641/mcp \
     --header "Authorization: Bearer <token from the banner>"
   ```

   **ChatGPT** can only reach a public HTTPS endpoint, so it additionally needs
   you to expose the local server through a tunnel (OpenAI's secure tunnel,
   `cloudflared`, etc.). That sends transcript snippets through a public
   endpoint to OpenAI — opt in deliberately.

> **Privacy.** Embedding and indexing are fully on-device, but *answering*
> happens in whichever chat model you connect — so transcript snippets are
> sent to that model's provider (Anthropic for Claude, OpenAI for ChatGPT)
> when it reads a result, exactly as if you had pasted them in. The local
> endpoint is loopback-bound and token-guarded; only the ChatGPT-via-tunnel
> path widens that surface. The design rationale lives in
> [docs/adr/0001-http-only-mcp-daemon.md](docs/adr/0001-http-only-mcp-daemon.md).

## Replicate to a server you control (opt-in)

The local MCP only answers when your Mac is awake. If you want an always-on
agent to query your huske context 24/7, you can run a single-tenant **huske
server** on a box you control (e.g. a VPS). `huske run` then pushes each
finalized transcript to it (dependency-free, out-of-band — recording never waits
on the network); the server indexes them with a CPU embedder and serves the same
`search`/`fetch` MCP over loopback to a co-located agent. Only a **write-only
ingest endpoint** is exposed publicly — your transcript history is never readable
over the network.

```toml
# ~/.config/huske/config.toml on your Mac
sync_endpoint = "https://huske.example.com"
```

```bash
huske sync     # one-shot backfill of your existing transcripts
huske serve    # on the VPS: receive + index (pair with `huske mcp` for reads)
```

Full setup (server install, systemd units, Caddy, tokens) is in
**[docs/server.md](docs/server.md)**; the rationale is in
[docs/adr/0004-off-device-huske-server.md](docs/adr/0004-off-device-huske-server.md).

## Privacy and consent

huske is local-first: audio capture and transcription run on your machine, and
the app writes transcripts to your configured filesystem path. That does not
make the data low-risk. Recordings, transcripts, logs, filenames, and device
metadata can contain private or legally sensitive information.

- Get consent before recording other people or regulated conversations.
- Do not commit generated audio, transcripts, logs, local configs, model caches,
  or screenshots containing private content.
- If you enable replication (`sync_endpoint`), your transcripts are copied to the
  huske server you configure. Run it only on infrastructure you control, over
  HTTPS, and treat that box as holding your full transcript history. See
  [docs/server.md](docs/server.md).
- The `--screenshots` flag captures everything visible on every attached
  display every 10 s — including any password manager popovers, banking
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
- [Off-device server](docs/server.md) — replicate transcripts to a VPS and serve
  them to a co-located agent (opt-in).
- [Architecture decisions](docs/adr/) — why the MCP daemon, search stack,
  embed-worker isolation, and off-device server are built the way they are.

## Community

- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Use issue templates for bugs, features, and documentation reports.
- Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) and include
  the exact checks you ran.
- For help, see [SUPPORT.md](SUPPORT.md).

## License

huske is released under the [MIT License](LICENSE). Third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
