# huske

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

- macOS 13 (Ventura) or newer on Apple Silicon.
- Python 3.11 or 3.12.

## Quickstart

```bash
# 1. Install
uv pip install -e ".[dev]"

# 2. Validate setup (will prompt for Screen Recording permission on first run)
huske doctor

# 3. Record (Ctrl+C to stop)
huske run

# 4. Reclaim orphans from a prior crash without recording
huske recover
```

On first launch macOS will prompt you to grant **Screen Recording** permission
to your Python interpreter — that's what ScreenCaptureKit needs to capture
system audio. After approving once, it's silent forever.

See [quickstart.md](specs/001-huske-recorder/quickstart.md) for the full setup.

## Documentation

- [Spec](specs/001-huske-recorder/spec.md) — what huske does and why.
- [Plan](specs/001-huske-recorder/plan.md) — technical context and architecture.
- [CLI contract](specs/001-huske-recorder/contracts/cli.md) — flags, exit codes.
- [Transcript format contract](specs/001-huske-recorder/contracts/transcript-format.md) — the LLM-consumer interface.
- [Quickstart](specs/001-huske-recorder/quickstart.md) — end-to-end setup.

## License

MIT.
