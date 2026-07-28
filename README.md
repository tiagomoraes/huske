# huske

[![CI](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> *huske* — Norwegian for "to remember"

A terminal app that runs in the background, continuously records your microphone
plus your computer's system audio, and transcribes the audio locally with
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
  (`--silence-split`, default 45 s) or at the `--chunk-minutes` cap (default
  30 min). Quiet stretches produce no file, and a conversation isn't cut
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
- **Local semantic search (opt-in MCP server)** — `huske[mcp]` adds on-device
  embedding + a local vector index so Claude Code, Claude Desktop, or ChatGPT
  can search your transcripts by meaning, recap a date range, and see what the
  corpus covers. Embeddings and the index never leave your machine; see
  [Search your transcripts from Claude / ChatGPT](#search-your-transcripts-from-claude--chatgpt-opt-in).
- **Reachable from your phone (opt-in)** — connector mode serves an OAuth 2.1
  sign-in beside the MCP endpoint, so Claude on iOS/web, ChatGPT, or a hosted
  agent can attach one HTTPS URL and query your transcripts *while the Mac is
  asleep*. Off by default, loopback-only until you set it; see
  [Reach it from any device](#reach-it-from-any-device-opt-in).
- **LLM distillation into searchable statements (opt-in)** — distil each
  transcript into compact, self-contained claims with a **local** LLM (Ollama),
  search those, and drill into the verbatim transcript on demand. Fully
  on-device, no new Python dependency, off by default; see [Distil transcripts
  into searchable statements](#distil-transcripts-into-searchable-statements-opt-in).
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
uv tool install "git+https://github.com/tiagomoraes/huske.git@v0.12.0"
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

## Search your transcripts from Claude / ChatGPT (opt-in)

The base install gives any LLM agent file access to `~/huske/transcripts/`. For
*semantic* search — "what did we decide about the pricing model last week?"
across months of calls — install the optional extra:

```bash
pip install 'huske[mcp]'   # mlx-embeddings + sqlite-vec + the MCP SDK
```

**The short version: open the Connect pane in Huske.app.** It shows what's left
and puts a button on each step — build the index, start the search server,
connect Claude Desktop or Claude Code. Nothing to type, and it merges into your
client's config rather than overwriting it. From a terminal, `huske setup` does
the same and tells you which step you're on.

The long version — what those steps actually are:

1. **Build the index.** `huske index` embeds every transcript under
   `output_root` into a single local vector file (`~/huske/index/passages.db`)
   using a multilingual model that runs on the Apple Silicon GPU via MLX —
   the same Metal stack `parakeet-mlx` already uses. Nothing leaves your machine.

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

   **Claude Code** connects directly — no tunnel:

   ```bash
   claude mcp add --transport http huske http://127.0.0.1:7641/mcp \
     --header "Authorization: Bearer <token from the banner>"
   ```

   **Claude Desktop and Cowork** can't attach a bearer header to a loopback URL
   through the connectors UI, so bridge the endpoint to a local stdio server
   with `mcp-remote` in
   `~/Library/Application Support/Claude/claude_desktop_config.json`:

   ```json
   {
     "mcpServers": {
       "huske": {
         "command": "npx",
         "args": [
           "-y", "mcp-remote", "http://127.0.0.1:7641/mcp",
           "--allow-http",
           "--header", "Authorization:${HUSKE_MCP_TOKEN}"
         ],
         "env": { "HUSKE_MCP_TOKEN": "Bearer <token from the banner>" }
       }
     }
   }
   ```

   Write `Authorization:` with no space (Claude Desktop strips spaces in args),
   then fully quit and reopen the app. Cowork shares this config, so huske shows
   up there too once Desktop reloads it.

   **Claude on your phone and ChatGPT** can only reach a public HTTPS endpoint
   with OAuth — see [Reach it from any device](#reach-it-from-any-device-opt-in).

The server exposes four tools. `search` and `fetch` are the semantic pair;
`recap` returns a **date range** whole and in order ("what happened today"), and
`overview` reports what the corpus covers so a model can tell an empty index from
an unlucky query. A date is not a semantic neighborhood, so asking `search` for
"yesterday" returns whatever *sounds* like the word — `recap` is what makes
"catch me up" work. Two prompts (`catch_me_up`, `what_was_said_about`) ship with
it, so clients that surface server prompts get one-tap actions.

> **Privacy.** Embedding and indexing are fully on-device, but *answering*
> happens in whichever chat model you connect — so transcript snippets are
> sent to that model's provider (Anthropic for Claude, OpenAI for ChatGPT)
> when it reads a result, exactly as if you had pasted them in. The local
> endpoint is loopback-bound and token-guarded. The design rationale lives in
> [docs/adr/0001-http-only-mcp-daemon.md](docs/adr/0001-http-only-mcp-daemon.md).

## Reach it from any device (opt-in)

The loopback daemon answers from the Mac it runs on. If you want the same context
from **Claude on your iPhone, ChatGPT, or a hosted agent** — including while that
Mac is asleep — turn on **connector mode** wherever your always-on index lives
(the [huske server](#replicate-to-a-server-you-control-opt-in) on a VPS, ideally).

Neither Claude nor ChatGPT lets you paste a bearer header into a connector; both
speak the MCP authorization spec instead. So `huske mcp` can serve a small
single-tenant OAuth 2.1 authorization server alongside the MCP endpoint — one
passphrase, one read-only scope, no accounts, no external identity provider.

```bash
huske mcp set-password                                          # scrypt-hashed, 0600
huske config set mcp_public_url https://huske.example.com/mcp
huske mcp                                                       # still binds loopback
```

Point a TLS reverse proxy at it (an allowlist of `/mcp`, `/.well-known/oauth-*`,
and `/oauth/*` — never a catch-all), then add that one URL as a custom connector
in Claude (Settings → Connectors) or ChatGPT (Settings → Connectors → Advanced).
Sign in once with your passphrase; it stays connected across devices.

Loopback clients are untouched: Claude Code and a co-located agent keep using the
static token on `127.0.0.1`, and the daemon refuses to start in connector mode
without a passphrase or over plain HTTP.

```bash
huske connect                  # per-client wiring, and whether it works today
huske connect claude-app       # exact steps for one client
huske mcp status               # is it configured? how many devices attached?
huske mcp revoke --all         # cut every device off
```

**Not every destination speaks MCP.** For a Claude Project, NotebookLM, an
Obsidian vault, or a shared folder, `huske export` writes **one Markdown file per
day** (distilled key points first, verbatim conversation below) — incremental and
atomic, so a sync client never uploads a partial file:

```bash
huske export                    # → ~/huske/export/YYYY-MM-DD.md
huske export --statements-only  # key points only
```

That is a complement, not a substitute: you trade semantic search, statement
grounding, and date/source filters for whatever full-text search the destination
has — and syncing it to a third-party cloud puts plaintext transcripts there.

Full guide, per client, with the security posture and troubleshooting:
**[docs/integrations.md](docs/integrations.md)**. Rationale, and why it amends
the loopback-only decision in ADR 0004:
[docs/adr/0008-public-mcp-connector.md](docs/adr/0008-public-mcp-connector.md).

## Distil transcripts into searchable statements (opt-in)

Semantic search over raw passages works, but conversational speech is verbose.
huske can also distil each transcript into compact, self-contained **statements**
— "We approved the Q3 marketing budget", "The roadmap ships Friday" — using a
**local** LLM, then search *those* and drill into the verbatim transcript only
when a statement looks relevant. Two-stage retrieval: find the claim, then read
what was actually said.

It runs entirely on-device through a local LLM daemon
([Ollama](https://ollama.com)) and adds **no Python dependency** (a loopback HTTP
call). Off by default.

```bash
# 1. Install Ollama, then pull any model — pick for your RAM:
ollama pull gemma4:e2b      # ~2-4 GB resident, multilingual — the default
# or: ollama pull qwen3:4b  (higher quality)  ·  llama3.2:3b  (lightest)

# 2. Distil your history into <name>.statements.json sidecars (incremental):
huske distill                       # --fast for full speed; --model to override

# 3. Embed the statements for search (needs the huske[mcp] extra):
huske index                         # also embeds any statement sidecars
```

To keep statements fresh automatically, in `~/.config/huske/config.toml`:

```toml
distill_enabled = true        # distil each finished transcript in the background
distill_model   = "gemma4:e2b"
indexing_enabled = true       # also embed them so `huske mcp` searches statements first
```

With both on, `huske run` distils and embeds each transcript off the hot path —
an LLM call never blocks recording, and if the daemon is down, recording and
passage search continue while `huske distill` catches up later. `huske mcp` then
ranks **statements** first, and `fetch` returns the matched claim **plus the
source transcript** that grounds it. `huske doctor` validates the daemon + model
when `distill_enabled` is set. Rationale:
[docs/adr/0005-llm-distillation.md](docs/adr/0005-llm-distillation.md); full
guide: [docs/distillation.md](docs/distillation.md).

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
- If you enable connector mode (`mcp_public_url`), that server will answer
  *read* queries for your transcripts over the internet to anyone holding a token
  minted by your passphrase. It is the one setting here that does so. Use a strong
  passphrase, keep the reverse proxy to the documented path allowlist, enable
  full-disk encryption on that box, and `huske mcp revoke --all` if a device is
  lost. See [docs/integrations.md](docs/integrations.md#security-posture).
- If you run `huske export` and sync that folder to a third-party cloud (Drive,
  Dropbox, iCloud), plaintext transcripts are stored there under that provider's
  retention and scanning policy. Prefer `--statements-only` if you do.
- If you enable distillation (`distill_enabled`), transcript text is sent to the
  local LLM daemon you run. By default that is Ollama on loopback — on-device, so
  it stays on your machine; only pointing `distill_endpoint` at a remote daemon
  would change that.
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
- [Off-device server](docs/server.md) — replicate transcripts to a VPS and serve
  them to a co-located agent (opt-in).
- [Transcript distillation](docs/distillation.md) — distil transcripts into
  searchable statements with a local LLM (opt-in).
- [Architecture decisions](docs/adr/) — why the MCP daemon, search stack,
  embed-worker isolation, off-device server, and public connector are built the
  way they are.

## Community

- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Use issue templates for bugs, features, and documentation reports.
- Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) and include
  the exact checks you ran.
- For help, see [SUPPORT.md](SUPPORT.md).

## License

huske is released under the [MIT License](LICENSE). Third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
