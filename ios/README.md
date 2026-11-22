# Huske for iPhone

A simple voice recorder whose recordings sync automatically to **your own Mac**,
where Huske transcribes them. No cloud, no account. The transcript comes back to
the phone once the Mac has finished.

- Records AAC-LC `.m4a` (mono, 48 kHz, ~64 kbps) and keeps recording when the
  phone is locked. A call pauses it, and you choose when to resume.
- A Live Activity on the Lock Screen and in the Dynamic Island shows the
  running timer and a red dot, with Pause/Resume and Stop buttons. There is no
  level meter there: iOS redraws a Live Activity only now and then, and a meter
  that stands still reads as "not recording" while it records fine.
- **Action button and Control Center.** The "Huske Record" control starts a
  recording without opening the app, and the next press stops and saves it.
  Assign it in Settings › Action Button › Controls, or add it to Control Center.
- **Shortcuts and Siri.** Start (optionally named), Start or Stop, Stop, Pause or
  Resume, Get Latest Transcript, Get Transcript, Open Recording and Find
  Recordings. See [Shortcuts](#shortcuts).
- Pairs with Huske on the Mac through a QR code or a `huske://pair?…` link. Sync
  runs over the local network (Bonjour + TLS-PSK) through the shared
  [`HuskeSync`](../macos/Sources/HuskeSync) library. See
  [`specs/002-phone-sync`](../specs/002-phone-sync/contracts).

## Build

Requirements: Xcode 26+ (developed with Xcode 27 and the iOS 27 simulators) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The
deployment target is iOS 18 (it runs on every iPhone that iOS 17 does, and
brings the control and background recording from an App Intent).

```bash
cd ios && ./scripts/generate.sh   # runs xcodegen; Huske.xcodeproj is git-ignored
open Huske.xcodeproj
```

Command line:

```bash
xcodebuild -project ios/Huske.xcodeproj -scheme Huske \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild test -project ios/Huske.xcodeproj -scheme Huske \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run `./scripts/generate.sh` again whenever you add or remove files or edit
`project.yml`. It wraps `xcodegen` and stamps the app version from
`../pyproject.toml`, the repo's single source of truth for versions.

### Signing

Simulator builds need no signing team. To run on a device, set
`DEVELOPMENT_TEAM` in `project.yml` (or in Xcode's Signing pane), then run
`xcodegen` again. The project owner's team is `QD5A8CZK76`. Bundle IDs:
`cloud.tiagomoraes.huske.ios` (app) and
`cloud.tiagomoraes.huske.ios.LiveActivity` (widget extension).

## Layout

| Path | What |
|---|---|
| `Huske/App` | App entry, composition root (`AppModel`), App Shortcuts (Siri phrases), DEBUG demo data |
| `Huske/Intents` | Shortcuts actions that read the library (`RecordingEntity`, transcripts, open) or act on the recording in progress |
| `Huske/Recording` | `RecorderController` (AVAudioRecorder, interruptions, routes), Live Activity controller, crash recovery |
| `Huske/Library` | `Recording` model, JSON `LibraryStore`, list, detail, player, transcript parser |
| `Huske/Sync` | `SyncManager` (the link supervisor; upload → poll → fetch transcript), `LinkState` (why it isn't syncing), `SyncJournal`, badge mapping, BGTaskScheduler, transport and network-path seams over HuskeSync |
| `Huske/Pairing` | Keychain pairing store, link parsing glue, Mac screen (link status, Copy details), QR scanner |
| `Huske/UI` | Root view, recorder panel, shared components |
| `Shared` | Brand tokens, `ActivityAttributes`, App Intents. Compiled into both the app and the extension |
| `HuskeLiveActivity` | Widget extension: Live Activity, Dynamic Island, "Huske Record" control (Control Center, Lock Screen, Action button) |
| `HuskeTests` | Unit tests (library store, badges, pairing links, titles, transcript parser, recovery, and sync against a scripted Mac: `SyncManagerTests`, `LinkSupervisorTests`, `SyncSafetyTests`, `LinkStateTests`, `SyncJournalTests`, `PairingSecurityTests`, `PartialTranscriptTests`) |
| `HuskeUITests` | `HuskeScreenshots` scheme: screenshot tour for design review, Action button tests, pairing-link feedback |

Fonts (IBM Plex) are bundled directly from `macos/Sources/Huske/Resources/Fonts`.
The app icon is rendered by `scripts/generate-icon.swift`.

## Shortcuts

Every action runs in the app's process without bringing it to the screen
(except Open Recording).

| Action | What it does |
|---|---|
| Start or Stop Recording | Starts a recording, or stops and saves the one in progress. Pick it under Settings › Action Button › Shortcut; the *Huske Record* control does the same. |
| Start Recording | Starts a new recording, optionally with a title. |
| Stop Recording | Stops and saves the recording in progress and returns it. |
| Pause or Resume Recording | Toggles pause on the recording in progress. |
| Get Latest Transcript | The newest transcript, as plain text (what was said) or Markdown (timecodes and sources). |
| Get Transcript | The transcript of a chosen recording, in either format. |
| Open Recording | Opens a recording in Huske. |
| Find Recordings | Generated by Shortcuts: filter and sort by title, date, duration, status, transcript. |

The first five also answer to Siri ("Start a Huske recording", "Get my latest
Huske transcript") and appear in Spotlight and under Settings › Action Button ›
Shortcut. Allow the microphone once from the app first: iOS can only ask for
that permission while the app is on screen.

Two things the platform requires, both learned the hard way:

- **A background start is an `AudioRecordingIntent` *and* a `LiveActivityIntent`.**
  The first lets the app open the microphone from the background as long as a
  Live Activity shows the recording; the second is what lets it start that Live
  Activity there (without it, `Activity.request` fails with "Target is not
  foreground"). The recorder requests the activity before the microphone.
- **A background start uses a session that mixes with other audio.** iOS
  refuses to activate an exclusive `playAndRecord` session for an app in the
  background ("Session activation failed", seen on an iPhone 15 Pro; the
  simulator doesn't enforce it). `AudioStarter` adds `.mixWithOthers` only for
  background starts; a start from the app stays exclusive, so music stops.
- **Shortcuts-facing intents live in the app target only** (`Huske/Intents`). An
  intent compiled into both the app and the widget extension can be resolved
  through the extension, which has no App Shortcuts and no recorder ("Couldn't
  find AppShortcutsProvider"). The control and the Live Activity buttons use
  their own intents in `Shared/`, hidden from Shortcuts.

`HuskeUITests/ActionButtonTests` exercises all of this on a simulator: the
control assigned to the Action button, "Record or Stop" from Spotlight with the
app closed (Dynamic Island, Lock Screen pause/resume, stop), and the control in
Control Center. XCTest can't press-and-hold the simulator's Action button, so
that last step needs a device.

## Sync

`SyncManager` supervises the link to the paired Mac by events, not by a timer.

- **One browse.** A single `MacPresenceMonitor` (Bonjour, with peer-to-peer)
  says where the Mac is. A pass connects straight to that endpoint with
  `SyncClient.connect(to:)`; it never starts a browse of its own, and it isn't
  attempted at all while the Mac isn't visible. (Browsing per attempt cost
  most of a second each time, and 8 s when the Mac was away.)
- **What starts sync again:** the Mac appears on the browse or is seen another
  way (Wi-Fi ↔ direct), the network path changes (`NWPathMonitor`), the app
  comes to the front, a recording is saved, "Sync now", and background tasks.
- **Backoff only when it makes sense.** A pass that fails with the Mac still
  visible is retried after 2 s, doubling to 60 s, each ±20 %. Any of the events
  above starts the count over and tries at once. A Mac that refuses this
  iPhone's key is never retried on a clock.
- **Looking costs battery.** The browse and the path monitor run only while
  the app is on screen or a pass is running. A pass in the background (a
  recording stopped from the Lock Screen, a `BGTask`) starts the browse, waits
  up to 8 s for the Mac, and stops it when it ends. "Sync now" and pairing
  wait the same 8 s; everything else on screen just waits for the browse.
- **Polling.** After an upload the phone asks for `status` every 2 s while the
  Mac is transcribing and the app is on screen, easing off to 10 s while
  recordings only wait in line. In the background it polls for 20 s, and a
  pass with nothing to send, fetch or poll doesn't connect.

**Why isn't it syncing.** `SyncManager.link` is one typed `LinkState`, drawn
the same way on the Mac screen and in the home header (a glyph and plain
words, DESIGN.md "Quiet instrument"):

| State | Words | Way out |
|---|---|---|
| `localNetworkOff` | Local Network access is off | Open Settings (button) |
| `noWiFi` | Not on Wi-Fi | Join the Mac's Wi-Fi, or turn Wi-Fi on and stay close |
| `rejected` | Your Mac didn't accept this iPhone | Scan a new pairing code (button) |
| `searching` | Looking for your Mac… | Open Huske on the Mac (shown after a few seconds) |
| `visible` | Nearby | — |
| `connecting` | Connecting… | — |
| `connected` | Connected over Wi-Fi / Connected directly | — |
| `retrying` | Couldn't connect · trying again in N s | — |
| `paused` | Not looking right now (background) | — |

**Copy details.** `SyncJournal` keeps the last 200 sync events
(`sync-journal.json`, beside the library): link changes, attempts, errors,
timings, sizes. The Mac screen's *Copy details* puts them on the clipboard
with the app version and the current state, for a support message. It never
holds audio, transcript text, recording titles, device or Mac names, or keys;
recordings appear as the first 8 characters of their ID.

**Pairing is safe to repeat.** With a Mac already paired, a new code is tried
against its Mac first and replaces the pairing only once that Mac answers. A
code the Mac no longer accepts ("This code didn't work — make a new one on
your Mac") or a Mac that can't be reached leaves the current pairing as it
was. A first code that the Mac refuses is not kept.

**The code's key is replaced right after pairing** (`pairing.rekey`,
sync-protocol.md § Key rotation). The phone asks over the paired connection,
stores the Mac's answer as `PairedMac.pending`, proves it on a second
connection and only then makes it the pairing's key (`rotatedAt`); the Mac
retires the code's key when it sees the new one used. With two keys stored the
new one goes first, and only a *refusal* of it lets the old one have a turn
(`SyncManager.openSession`); no key is ever dropped on the phone's own
judgement. A rotation still owed (the code's key with a Mac that rotates, or a
pending key) is a reason to connect by itself, so one that was cut short
finishes the next time the Mac is seen rather than at the next recording.
`PairingSecurityTests` covers every interruption point against a scripted
Mac with a registry (`KeyedMac`).

**Forget this Mac** forgets on the phone first, then, if the Mac is visible
and announced `pairing.unpair`, connects (with whichever key it takes) and
asks it to remove this iPhone. Not reachable or too old: the Mac keeps listing
the iPhone until it is removed there.

**Naming the Mac.** What the phone shows is `SyncManager.macName`. It is the
name given on this iPhone (`macNickname`, the **Name** field in Mac
settings), or else the Mac's own name: the name from the pairing code,
replaced by each `welcome` (`macOwnName`). The given names are stored in
UserDefaults keyed by `macID`, outside the Keychain pairing record. That way
a `welcome` never overwrites them, and pairing the same Mac again keeps
them. The name is local to the phone; the Mac never sees it.

**Pairing again** replaces the Mac's earlier entry for this iPhone:
`InstallIdentity` is a random ID kept in the Keychain (this device only, so it
survives reinstalling but not a move to another iPhone) and sent as
`hello.installID` — only with the pairing the phone keeps, never while a new
code is merely being tried (`MacConnecting.asCandidate`).

**Network or file.** `SyncError.network` (refused, no route, name not
resolved) ends the pass and is retried; a refused connection reads "… isn't
accepting connections — open Huske on your Mac". `SyncError.io` is only the
recording's own file: that recording fails, the rest go out.

**Chunk size.** Uploads start at 256 KiB per `chunk`, double while chunks are
acknowledged within a second (up to the 1 MiB frame limit every Mac accepts)
and halve when one takes over five, so a slow link waits for far fewer round
trips (`UploadChunkSizer` in HuskeSync).

DEBUG builds can stand in for the app as it was before all of this:
`-HuskeLegacyPeer YES` announces no capabilities and sends no install ID.

**Retry.** A recording that couldn't be sent ("Couldn't send") is sent again.
One the Mac gave up on ("Couldn't transcribe") is offered again: the Mac still
has the audio, queues it once more and answers `skip`, and the phone resumes
polling (sync-protocol.md § Retrying). Deleting a recording while it is being
sent stops its upload.

**Partly transcribed.** When the Mac gives up on a long recording with some
of its parts done, it says so (`RemoteStatus.partial`) and the phone fetches
those parts. They are stored in `Recording.partialTranscript`, apart from
`transcript`, so the recording still counts as not transcribed: the row reads
"Partly transcribed — Retry", the detail screen says "Part of this recording
couldn't be transcribed — 2 of 3 parts are below." over the text, and Retry
works as for any failure. The Mac then transcribes only the missing parts, and
the whole transcript replaces the partial one. A Mac that predates this
(`transcript.partial` not announced) reports a plain failure, as before.

**Tried again on the Mac.** A failure is final for polling, so each time the
app comes to the front the next pass asks the Mac once about the recordings it
had given up on (`Recording.wasGivenUpOn`), and follows any that moved on:
"Try again" in Huske on the Mac reaches the phone without a tap here.

**"Trying again on your Mac"** comes from `RemoteStatus.retrying` when the Mac
sends it (`status.retry`), with "attempt 2 of 3" when it counts; from an older
Mac the phone still reads it off the status text.

Everything above runs against a scripted Mac in `HuskeTests`: `FakePresence`
plays the browse, `FakePath` the network path, `FakeMac`/`FakeConnector` the
Mac, and the clock and delays are injected.

## Data

The library index (`library.json`) and the audio files (`Recordings/<id>.m4a`)
live in `Application Support/Huske` and are excluded from iCloud backup: the
copy that matters is the one on your Mac. Deleting a recording on the phone
never deletes it on the Mac. The pairing (the Mac's ID and this phone's
pre-shared key) is kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`).
The sync journal (`sync-journal.json`, see [Sync](#sync)) lives in the same
folder.

A recording is added to the library as `inProgress` *before* its first sample
is written. If the app dies while recording, the next launch finalizes the file
if it is readable. Otherwise it marks the recording **Damaged**: AVAudioRecorder
writes the `.m4a` index only when it stops, so a file cut short by a crash is
usually unreadable.

## Demo mode (DEBUG builds)

These launch arguments make it possible to review screens without a Mac or a
working microphone:

| Argument | Effect |
|---|---|
| `-HuskeDemoData YES` | Throwaway library with sample recordings in every sync state, plus a fake paired Mac (sync is frozen) |
| `-HuskeDemoPaired NO` | Demo library, but no Mac paired |
| `-HuskeDemoRoute detail` / `mac` | Open a recording's detail screen, or the Mac screen |
| `-HuskeDemoRecording YES` | Simulated recording with synthetic levels. Starts the real Live Activity |
| `-HuskeAutoRecord YES` | Start a real recording one second after launch |
| `-HuskeAutoStopAfter <s>` | With `-HuskeAutoRecord`: stop and save after `<s>` seconds (unattended end-to-end tests) |
| `-HuskeAutoConfirmPairing YES` | Press "Pair" automatically for an opened pairing link |
| `-HuskeOpenURL <url>` | Handle a `huske://pair?…` link at launch |
| `-HuskeSeedSampleRecording YES` | Add a finished 20 s tone recording to the real library (sync without a mic) |
| `-HuskeSeedAudioFile <path>` | Add a copy of a host audio file (e.g. a spoken `.m4a`) as a finished recording |

```bash
xcrun simctl launch booted cloud.tiagomoraes.huske.ios -HuskeDemoData YES -HuskeDemoRoute detail
xcrun simctl openurl booted 'huske://pair?v=1&mac=…&name=…&id=…&key=…'
```

The `HuskeScreenshots` scheme runs a UI-test tour that saves PNGs (in-app
recording, Dynamic Island, Lock Screen) to `$HUSKE_SHOT_DIR` (pass it as
`TEST_RUNNER_HUSKE_SHOT_DIR=… xcodebuild test -scheme HuskeScreenshots …`).
