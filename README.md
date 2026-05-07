# huske

[![CI](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/tiagomoraes/huske/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> *huske* — Norwegian for "to remember"

A terminal app that runs in the background, continuously records your microphone
plus your computer's system audio, and transcribes the audio locally with
[faster-whisper](https://github.com/SYSTRAN/faster-whisper) — producing a
day-organized, LLM-friendly knowledge base of everything that was said on your
machine throughout the day.

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

- **Continuous capture** — mic (sounddevice) + system audio (Apple ScreenCaptureKit),
  mixed in software, no gaps at chunk boundaries.
- **No drivers, no Audio MIDI Setup** — system audio comes through Apple's
  modern ScreenCaptureKit framework. Just grant Screen Recording permission once.
- **Local transcription** — `faster-whisper`, default `base` model. Audio never
  leaves your machine.
- **Configurable chunk size** — default 15 minutes, anything from 6 s to 60 min.
- **Resilient** — graceful stop finalizes the partial chunk; SIGKILL + restart
  auto-recovers orphaned audio.
- **Pretty terminal UI** — Rich Live panel with countdown, mic + system level
  meters, queue depth, last-saved transcript, rolling event log.
- **LLM-ready output** — every transcript is a single Markdown file with full
  YAML frontmatter; the directory layout is documented in
  `~/huske/transcripts/README.md` (auto-generated).

## Requirements

- macOS 13 (Ventura) or newer. Apple Silicon is the primary target.
- Python 3.11, 3.12, or 3.13.

## Quickstart

```bash
# 1. Install with Homebrew (recommended on Apple Silicon macOS)
brew tap tiagomoraes/huske
brew install huske

# 2. Validate setup (will prompt for Screen Recording permission on first run)
huske doctor

# 3. Record (Ctrl+C to stop)
huske run

# 4. Reclaim orphans from a prior crash without recording
huske recover
```

Python tool installers work too:

```bash
uv tool install huske

# or:
pipx install huske
```

On first launch macOS will prompt you to grant **Screen Recording** permission
to your Python interpreter — that's what ScreenCaptureKit needs to capture
system audio. After approving once, it's silent forever.

For prerelease builds or exact GitHub tags, install directly from the repository:

```bash
uv tool install "git+https://github.com/tiagomoraes/huske.git@v0.1.0"
```

See [quickstart.md](specs/001-huske-recorder/quickstart.md) for the full setup.

## Privacy and consent

huske is local-first: audio capture and transcription run on your machine, and
the app writes transcripts to your configured filesystem path. That does not
make the data low-risk. Recordings, transcripts, logs, filenames, and device
metadata can contain private or legally sensitive information.

- Get consent before recording other people or regulated conversations.
- Do not commit generated audio, transcripts, logs, local configs, model caches,
  or screenshots containing private content.
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

## Community

- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Use issue templates for bugs, features, and documentation reports.
- Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) and include
  the exact checks you ran.
- For help, see [SUPPORT.md](SUPPORT.md).

## License

huske is released under the [MIT License](LICENSE). Third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
