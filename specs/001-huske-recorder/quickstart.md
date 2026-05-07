# Quickstart: Huske

**Date**: 2026-05-07
**Branch**: `001-huske-recorder`
**Audience**: developer setting up huske for the first time on macOS.

---

## Prerequisites

- **macOS 13 (Ventura) or newer** on Apple Silicon.
- **Python 3.11 or 3.12** (3.13 not yet supported by faster-whisper wheels at the time of writing).
- ~3 GB free disk for the default `base` Whisper model.

That's it. **No BlackHole, no Aggregate Device, no Audio MIDI Setup.**

---

## 1. Install

From the project root:

```bash
# Recommended: isolated install via uv
uv pip install -e ".[dev]"

# or pipx / pip
pipx install .
```

The first time `huske run` actually transcribes a chunk, it'll download the
Whisper `base` model (~150 MB) into the `huggingface` cache.

---

## 2. Validate the setup

```bash
huske doctor
```

Expected output on a healthy first install:

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

If `system audio` shows ✗ "Screen Recording permission not granted", see step 3.

---

## 3. Grant Screen Recording permission (once)

On first launch, macOS shows the standard Screen Recording prompt because
ScreenCaptureKit is what huske uses to capture system audio.

1. Run `huske run` (or `huske doctor`) once. macOS will pop a dialog asking
   permission for your Python interpreter.
2. Click **Open System Settings** in that dialog (or open it manually:
   System Settings → Privacy & Security → **Screen Recording**).
3. Toggle the switch next to **Python** (or your launcher) to **on**.
4. Quit and re-run huske — the permission only takes effect on next launch.

The grant is per-binary-path. If you switch Python environments (e.g.,
re-install into a different `.venv`), you'll be prompted again for that new
interpreter.

---

## 4. Start recording

```bash
huske run
```

You'll see a Rich live status panel:

```text
┌─ huske 0.1.0 ──── session 8a3f2c19 ───── ~/huske/transcripts ─┐
│                                                               │
│  ● RECORDING       chunk 1 (00:03:42 / 15:00)                 │
│                    next rotation in 11:18                     │
│                                                               │
│  mic level   ▇▇▇▇▇▆▃▁▁                  −16 dB                │
│  sys level   ▇▇▇▆▅▃▂▁▁                  −22 dB                │
│                                                               │
│  queue       0 transcriptions pending                         │
│  last saved  (none yet)                                       │
└───────────────────────────────────────────────────────────────┘
```

Talk into your mic. Play music or have a video call. Both sources show
activity on the meters and end up in the same transcript, mixed.

Press **Ctrl+C** to stop. The current partial chunk is finalized,
transcribed, and saved before the process exits.

---

## 5. Inspect the output

```bash
tree ~/huske/transcripts/
```

```text
~/huske/transcripts/
├── 2026-05-07/
│   ├── 091500_8a3f2c19_001.md
│   ├── 093000_8a3f2c19_002.md
│   └── 094500_8a3f2c19_003.md
└── README.md
```

Open one:

```yaml
---
session_id: 20260507T091500_8a3f2c19
chunk_seq: 1
date: 2026-05-07
start_time: 2026-05-07T09:15:00-03:00
end_time: 2026-05-07T09:30:00-03:00
duration_seconds: 900
duration_actual_seconds: 900.0
gap_seconds: 0.0
audio_sources: [microphone, system]
model: faster-whisper:base
language: en
incomplete: false
huske_version: 0.1.0
---

# 09:15 – 09:30 (Wed 2026-05-07)

[transcript body…]
```

---

## 6. Customize

Drop a TOML config at `~/.config/huske/config.toml`:

```toml
chunk_minutes = 10
model = "small"
language = "pt"
output_root = "~/Documents/huske"
```

Re-run `huske doctor` to confirm, then `huske run`.

---

## 7. If huske crashes or your machine reboots

On the next start, huske auto-detects orphaned audio and processes it.
To do this without starting a new recording:

```bash
huske recover
```

Damaged-beyond-repair WAVs land in `~/huske/audio/incomplete/` rather
than being silently lost.

---

## 8. Pointing Claude Code (or another LLM agent) at the output

The transcripts are plain Markdown files with YAML frontmatter, in a
documented structure (`~/huske/transcripts/README.md` is auto-generated).
Typical follow-ups:

```bash
# In a Claude Code session
cd ~/huske/transcripts
# "Summarize what I worked on yesterday"
# "Create Todoist todos for any commitments I made between 14:00 and 15:00 today"
```

The agent reads files directly — no bespoke parsing tooling required.

---

## Tips

- **Use headphones** if you want clean separation between mic and system
  audio. With speakers, the mic re-captures system output, leading to
  doubled / echoed speech in the transcript.
- **Quiet system audio** (e.g., a long meeting where you barely hear the
  other party) may not transcribe well — Whisper has a quality floor. The
  `small` or `medium` model helps significantly over `tiny`.
- **Privacy**: any audio playing on your Mac while huske is running is
  captured. If you join calls, the other party's voice is in the recording.
  Local-only processing keeps it on your machine, but consent laws vary.
