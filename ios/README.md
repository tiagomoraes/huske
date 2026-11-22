# Huske for iPhone

A simple voice recorder whose recordings sync automatically to **your own Mac**,
where Huske transcribes them. No cloud, no account. The transcript comes back to
the phone once the Mac has finished.

- Records AAC-LC `.m4a` (mono, 48 kHz, ~64 kbps) and keeps recording when the
  phone is locked. A call pauses it, and you choose when to resume.
- A Live Activity on the Lock Screen and in the Dynamic Island shows the timer
  and a level meter, with Pause/Resume and Stop buttons.
- Pairs with Huske on the Mac through a QR code or a `huske://pair?…` link. Sync
  runs over the local network (Bonjour + TLS-PSK) through the shared
  [`HuskeSync`](../macos/Sources/HuskeSync) library. See
  [`specs/002-phone-sync`](../specs/002-phone-sync/contracts).

## Build

Requirements: Xcode 26+ (developed with Xcode 27 and the iOS 27 simulators) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The
deployment target is iOS 17.

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
| `Huske/App` | App entry, composition root (`AppModel`), App Shortcuts, DEBUG demo data |
| `Huske/Recording` | `RecorderController` (AVAudioRecorder, interruptions, routes), Live Activity controller, crash recovery |
| `Huske/Library` | `Recording` model, JSON `LibraryStore`, list, detail, player, transcript parser |
| `Huske/Sync` | `SyncManager` (upload → poll → fetch transcript), badge mapping, BGTaskScheduler, transport seam over HuskeSync |
| `Huske/Pairing` | Keychain pairing store, link parsing glue, Mac screen, QR scanner |
| `Huske/UI` | Root view, recorder panel, shared components |
| `Shared` | Brand tokens, `ActivityAttributes`, App Intents. Compiled into both the app and the extension |
| `HuskeLiveActivity` | Widget extension: Live Activity, Dynamic Island, Control Center "Record" control (iOS 18+) |
| `HuskeTests` | Unit tests (library store, badges, pairing links, titles, transcript parser, recovery) |
| `HuskeUITests` | Screenshot tour for design review (`HuskeScreenshots` scheme) |

Fonts (IBM Plex) are bundled directly from `macos/Sources/Huske/Resources/Fonts`.
The app icon is rendered by `scripts/generate-icon.swift`.

## Data

The library index (`library.json`) and the audio files (`Recordings/<id>.m4a`)
live in `Application Support/Huske` and are excluded from iCloud backup: the
copy that matters is the one on your Mac. Deleting a recording on the phone
never deletes it on the Mac. The pairing (the Mac's ID and this phone's
pre-shared key) is kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`).

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
