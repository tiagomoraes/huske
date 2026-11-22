---
status: accepted
date: 2026-11-19
---

# WebRTC AEC3 echo cancellation on a single-clock capture

## Context

On speakers (no headphones), what the Mac plays (the remote side of a call, a
video) is re-captured by the microphone. Huske transcribes the mic and the
system channel separately, so every remote line came out twice.

Since 0.9 huske attacked this in two stages: a coherence-based **suppressor**
on the mic, then a transcript-level **text de-dup**. Sample-precise
cancellation had been tried and abandoned: the mic (PortAudio) and the system
tap (a separate Core Audio aggregate) ran on independent clocks, and their
alignment wandered over a chunk. In practice the duplicates kept coming.

Measured on synthetic speaker bleed, with real TTS voices and Whisper scoring
which of the remote side's words leak into the mic transcript:

| scenario (speakers) | raw mic | coherence suppressor | WebRTC AEC3 (this ADR) |
|---|---|---|---|
| remote talks, then local | 45/45 words leak | **45/45 leak** | 0/45 |
| both talk at once | 22/45 leak | 22/45 leak | 1–2/45, local voice intact (22/23) |
| headphones (no echo) | — | — | transparent (22/23) |

The suppressor removed about 8 dB of energy, but the attenuated echo was still
perfectly intelligible to the ASR. The text de-dup then had to catch each
duplicate by fuzzy text match against a system line up to 15 s away. That match
fails whenever the two ASR passes word the line differently.

Separately, the capture mixer's alignment had a defect. It padded the system
channel with zeros whenever the tap's delivery ran late for one 50 ms tick, and
the late samples were then appended *after* the padding. Every scheduling hiccup
therefore pushed the system channel permanently later, on top of real clock
drift between two devices.

**Verified on real hardware** (MacBook Pro built-in mic + speakers at 63 %
volume, macOS 27.2). A live `huske run` session recorded a Portuguese
"meeting" played on the speakers. The mic WAV and system WAV came out exactly
the same length, and the measured echo delay was a constant 62 ms. Whisper on
that real mic recording:

| real mic | remote words leaking |
|---|---|
| raw | 55/55 |
| coherence suppressor (11.5 dB removed) | 55/55 |
| WebRTC AEC3 (24 dB removed) | 2/55 |

The session's own transcript contains only the `system` line. `huske echo-test`
on the same machine reports 29.7 dB of bleed removed.

## Research: what the industry uses (2026-11)

Most tools that record a call (mic + system) and cancel speaker bleed run
**WebRTC AEC3** against a system-audio reference. Others either duck the
user's audio (Apple VPIO), run a neural canceller, or do nothing:

| Who | How |
|---|---|
| Chrome / Meet | WebRTC AEC3. Chromium can use a system-audio loopback as the reference "to be able to cancel echo from all audio processes" and delays the mic ~170 ms so the reference leads. |
| [Recall.ai desktop SDK](https://www.recall.ai/blog/acoustic-echo-cancellation) | WebRTC-based AEC |
| [RecordKit](https://nonstrict.eu/recordkit/guides/echo-cancellation.html) (macOS 14.2+) | AEC3 |
| [Savory](https://savory.ai/blog/both-sides-of-the-call-no-echo) | AEC (~20 dB) plus a transcript de-dup |
| [Screenpipe](https://github.com/screenpipe/screenpipe/issues/4256) | `sonora`, a Rust port of AEC3 (earlier experiments with VPIO) |
| [loopbacker](https://github.com/JacobCoffee/loopbacker/issues/14), [speecher](https://github.com/firemonster612/speecher/issues/236) | AEC3 with a Core Audio tap reference (speecher dropped VPIO over ducking) |
| Hyprnote / Char | DTLN-aec neural model (ONNX) |
| Meetily, OBS | none |

Python bindings available on Apple Silicon:

| Package | Status | Wheels | Adoption |
|---|---|---|---|
| **`livekit`** (`rtc.AudioProcessingModule`) | maintained (1.3.0, 2026-11) | `py3-none-macosx_11_0_arm64`, ~9 MB | LiveKit python-sdks ~394★; WebRTC itself is Google's |
| `pywebrtc-audio` | young (0.2.0, 2026-09) | cp310–cp314 | ~24★ |
| `webrtc-audio-processing` | abandoned (2018), pre-AEC3 | none | ~215★ |
| `speexdsp` | abandoned (2018), MDF canceller | none | ~129★ |
| `aec-audio-processing` | source only | none | — |

Apple's Voice Processing I/O (VPIO) was evaluated and rejected (see below).

## Decision

### 1. Cancel with WebRTC AEC3

The canceller is WebRTC's AEC3, the one used by Chrome and Meet. It is also
what most mic-plus-system recorders use: Chrome's own system-audio reference,
Recall.ai, Screenpipe (via a Rust port), RecordKit, and Savory. Huske reaches it
through LiveKit's `livekit.rtc.AudioProcessingModule` (Apache-2.0; arm64 macOS
wheel, works on every supported Python). It runs offline in the ASR worker, on
the chunk's 16 kHz mic + system arrays, before transcription.
`huske/transcribe/aec.py`:

- **Reference lead.** AEC3 needs the reference to *lead* the echo, by about
  0–400 ms. The worker measures the bulk mic↔system offset by cross-correlation,
  then shifts the streams so the echo sits 170 ms after the reference. That is
  the same margin Chromium adds for its system-audio reference. Without it, our
  tests saw AEC3 wipe out the local voice during double talk.
- **Stable vs wandering offsets.** When the per-window offsets of a chunk agree
  within 80 ms, which is the normal case with single-clock capture (below), the
  chunk is cleaned in one continuous pass. When they wander (older or fallback
  captures), each 120 s window gets its own alignment and its own canceller,
  warmed up on the preceding 4 s.
- **Echo-presence gate.** Mean mic↔reference coherence decides whether to run
  AEC3 at all. Speakers measure 0.1–0.4 (a faint echo 30 dB under the
  reference still measures 0.01); headphones measure about 0.001. Without an
  echo path AEC3 never converges and keeps a conservative suppressor engaged,
  which can dent the local voice. So the gate keeps it off.
- **Housekeeping.** AEC3's fixed 8 ms latency is compensated, so the cleaned
  mic keeps the original time base. Frames are always exactly 10 ms: any other
  length aborts the process inside the native library.
- `echo_canceller = auto | webrtc | coherence`. `auto` falls back to the old
  suppressor if the binding is missing or fails, and a chunk is never lost over
  echo handling. Text de-dup stays as the backstop.

### 2. Capture mic and system on one clock

When `capture_sync` is on (the default) and the Core Audio tap backend is in
use, the coordinator builds **one private aggregate device**:

- the microphone as its main sub-device (clock source);
- the global system-output tap in its tap list, with drift compensation, so
  Core Audio resamples the tap onto the mic's clock.

Do **not** set `kAudioAggregateDeviceTapAutoStartKey` on this aggregate. With
it, creation and `AudioDeviceStart` both succeed, but the IOProc is never
called (measured on macOS 27.2; the tap-only aggregate is unaffected).

One IOProc delivers both with identical frame counts
(`huske/capture/synced_capture.py`), and the per-source WAVs stay
sample-aligned for the whole session. This removes the drift and the padding
defect at the source, gives AEC3 a constant echo delay, and keeps the mic and
system timestamps in transcripts honest.

The aggregate is checked at start-up (stream layout, rate), resampled to the
pipeline rate when the mic clock differs (e.g. a 24 kHz Bluetooth headset), and
watched for stalls. Any failure, at start, on a mic switch, or on a mic-doctor
reclaim, falls back to the previous independent streams, with a warning event.

### Considered and rejected

- **Apple Voice Processing I/O.** Developers report it cancels other apps'
  playback on recent macOS. But it ducks the *user's* meeting audio (about
  4–15 dB even at minimum ducking), forces mono, cannot run on aggregate
  devices, and two voice-processing clients on one Mac cut each other off.
  Unacceptable for a passive, always-on recorder.
- **Other Python bindings:**
  - `speexdsp`: older MDF canceller, no arm64 wheels.
  - `webrtc-audio-processing` (2018): pre-AEC3, no wheels.
  - `pywebrtc-audio`: AEC3 and small, but young, with little adoption.
- **DTLN-aec** (Hyprnote's neural canceller). It works, but it needs an ONNX
  runtime and model weights, and it is not the community standard.

## Consequences

- New base dependency on Apple Silicon: `livekit` (~9 MB wheel plus protobuf,
  aiofiles). It is imported only in the ASR worker. The Homebrew tap needs its
  wheel at the next release.
- Costs about 1–2 % of real time in the worker (≈10 s for a 15-min chunk),
  small next to ASR.
- AEC3 attenuates the local voice by about 2–4 dB while the remote side is
  talking. That is inaudible to the ASR in our tests.
- `echo_cancel` keeps its meaning (on by default, self-gating). Two keys are
  new: `echo_canceller` and `capture_sync`.
