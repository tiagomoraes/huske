---
status: accepted
date: 2026-11-19
---

# iPhone recorder that syncs to the Mac for transcription

## Context

Huske records what happens at the Mac. Conversations away from the desk, such
as in-person meetings, a walk, or a call on the phone, were invisible to it. The
request: a simple iPhone recorder with Voice-Memos ergonomics (background
recording, Lock Screen / Dynamic Island controls) whose recordings land on the
user's own Mac and enter the normal transcription pipeline there. Transcribing
on the phone is not a goal.

Constraints carried over from the rest of Huske:

- **Local-first.** Audio never needs a third-party cloud or an account.
- **One engine** (ADR 0006). Transcription logic lives once, in the Python
  engine; app shells hand it work through the CLI and read on-disk contracts.
- **RAM is precious** (the footprint work). An import must not load a second
  ASR model next to a live session.

## Decision

### Transport: direct, paired, local + peer-to-peer

- The **Mac app** (always resident in the menu bar, open at login) runs a
  `SyncServer`. It is a Network.framework listener advertised over Bonjour as
  `_huske-sync._tcp`, with `includePeerToPeer`. The iPhone therefore reaches it
  on the same Wi-Fi, or over AWDL when the two are merely near each other, as
  AirDrop does.
- **Security** is TLS 1.2 with a pre-shared key per phone, the pattern of
  Apple's Network.framework peer-to-peer sample. Session resumption is disabled,
  so every connection proves the key; a wrong key fails the handshake.
- **Pairing** is one QR code. The Mac mints `{deviceID, 32-byte key}` and shows
  `huske://pair?...` as a QR. Scanning it with the system Camera opens the
  iPhone app, which stores the key in its Keychain. The first handshake turns
  the pending slot into a paired device. A **Copy link** button covers Universal
  Clipboard and the simulator.
- **Protocol** (`specs/002-phone-sync/contracts/sync-protocol.md`):
  length-prefixed JSON headers with binary bodies, and strict request/response.
  - `offer` → resume offset or `skip`.
  - 256 KiB `chunk`s.
  - `commit` with a SHA-256 check.
  - `status` / `transcript` for the round trip back to the phone.
  - Recording IDs make every step idempotent.
- The shared Swift library **`HuskeSync`** (in `macos/`, iOS 17+ / macOS 14+, no
  dependencies) implements both ends, so the protocol is tested end to end in
  `swift test`.

### Hand-off: the engine inbox

- Received audio goes to the engine through `huske inbox add --move` and
  `huske inbox process` (`specs/002-phone-sync/contracts/inbox.md`).
- Whichever process holds `inbox_root/.lock` transcribes. That is the live
  `huske run`, using its existing worker beside live chunks, or a one-shot
  `inbox process` when nothing is recording.
- AAC from the phone is decoded with macOS's own `afconvert`, so there is still
  no ffmpeg dependency.
- Recordings are split at quiet points into ≤ `chunk_minutes` pieces. They
  become ordinary Transcripts with deterministic session IDs, and carry
  additive frontmatter (`origin: phone`, `device`, `title`, `import_id`).
- The same path backs `huske import FILE…` for any audio file.

### The iPhone app

- SwiftUI, iOS 17+, generated with XcodeGen from `ios/project.yml`.
- **Recording.** AAC `.m4a` via `AVAudioRecorder`, in the background audio mode,
  with pause/resume and interruption handling.
- **Live Activity.** Shown on the Lock Screen and in the Dynamic Island, with
  App Intent buttons for pause/resume and stop.
- **Library.** Each recording carries a sync badge (Waiting for Mac → Uploading
  → Queued → Transcribing → Transcribed). When the transcript is ready, it comes
  back and is readable on the phone.
- **Uploads** start when a recording stops and retry whenever the Mac reappears
  on Bonjour, the app becomes active, or a background task runs.

### Considered and rejected

- **iCloud Drive / CloudKit.** It works anywhere, but needs matching iCloud
  entitlements and provisioning on a Developer-ID Mac app, and it puts private
  audio in Apple's cloud by default. Pairing would come from the Apple ID with
  no explicit consent step. It remains a possible second transport.
- **Hosting the receiver in the Python engine.** That would mean no AWDL, no
  TLS-PSK before Python 3.13, and a second implementation of the protocol.
  The app is already resident, so it hosts the receiver and the engine keeps
  owning transcription.
- **Transcribing on the phone.** It duplicates the engine and contradicts "one
  engine". It also gives worse models than the Mac's.

## Consequences

- Phone sync requires Huske.app to be running (it is a login item); with the app
  closed, the phone queues and retries.
- A new local-network surface: Huske.app accepts TLS-PSK connections only from
  phones the user paired, and can forget a device at any time. `Info.plist`
  gains `NSLocalNetworkUsageDescription` + `NSBonjourServices`.
- Releasing the iPhone app needs an Apple Developer team for signing; the
  project builds unsigned for the simulator.
