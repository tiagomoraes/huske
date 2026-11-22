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

- The **Mac app** (resident in the menu bar; see "Staying reachable" below)
  runs a `SyncServer`. It is a Network.framework listener advertised over Bonjour as
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
  - `chunk`s of 256 KiB to start with, sized by the link from there
    ("Pairing security and throughput").
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
- **A recording that fails partway keeps what it got** (amended 2026-11). A
  part that fails does not stop the others; the item ends `failed` with
  `missing_chunks`, and the transcripts of the finished parts stay. Huske.app
  hands them to the phone marked as partial (`transcript.partial`), and the
  phone shows them with Retry still there. The alternative, all or nothing,
  threw away an hour of good transcript over one bad stretch. Every later
  attempt, automatic or asked for, transcribes only the missing parts; the
  engine remembers the finished ones in `status.json`, so this is still one
  pipeline and no logic moved into the apps.

### The iPhone app

- SwiftUI, iOS 18+ (since the Action button / Shortcuts work; `HuskeSync` stays
  iOS 17+), generated with XcodeGen from `ios/project.yml`.
- **Recording.** AAC `.m4a` via `AVAudioRecorder`, in the background audio mode,
  with pause/resume and interruption handling.
- **Live Activity.** Shown on the Lock Screen and in the Dynamic Island, with
  App Intent buttons for pause/resume and stop.
- **Action button, Control Center, Shortcuts, Siri.** App Intents start, stop and
  pause recordings in the background (`AudioRecordingIntent` +
  `LiveActivityIntent`: iOS keeps a background recording only while a Live
  Activity shows it, and only a `LiveActivityIntent` may start one from the
  background) and expose recordings and transcripts as a Shortcuts
  entity. Nothing leaves the phone through them; they read the local library.
- **Library.** Each recording carries a sync badge (Waiting for Mac → Sending
  → Queued → Transcribing → Transcribed; "Couldn't send" and "Couldn't
  transcribe" are different failures, each with Retry). When the transcript is
  ready, it comes back and is readable on the phone.
- **Uploads** start when a recording stops and start again whenever the Mac
  appears on Bonjour, the network changes, the app becomes active, or a
  background task runs ("The phone's side of the link").

### Staying reachable (amended 2026-11)

A paired iPhone can only reach the Mac while Huske.app runs and its listener is
both bound *and* advertised. The first version got each of those wrong in a way
that looked fine from the Mac: a listener that failed stayed down until relaunch,
the pane said "Ready" from a bound port alone, and start-up ran only from the
main window. The receiver now looks after itself, in proportion:

- **The listener heals itself.** `SyncServer` restarts a failed listener with
  backoff (1 → 30 s). It counts as reachable (`SyncServerHealth.listening`) only
  once the system confirms the Bonjour registration; an advert that never
  registers, or is withdrawn, is announced again by rebuilding the listener. On
  wake (the app forwards `NSWorkspace.didWakeNotification`) and on network path
  changes (the server's own `NWPathMonitor`) it rechecks: a listener that is
  down or waiting is rebuilt at once, and a healthy one is verified by browsing
  for its own advert the way a phone does.
- **Start-up does not need a window.** The app delegate bootstraps at launch;
  the main window joins that run instead of being the only trigger. A login
  item, or a window closed at the last quit, used to start nothing.
- **Open at login is offered, not assumed.** It stays opt-in. Once a phone is
  paired the pairing sheet and the iPhone pane offer "Open Huske at login so
  your iPhone can always reach this Mac"; the user accepts or declines, and it
  is not shown again once on or declined.
- **Awake while there is work.** The app holds an idle-sleep assertion only
  while a recording is being received, handed to the engine, or transcribed by
  its own `inbox process` pass. Every reason is a lease with a deadline, so a
  phone that walks away mid-upload cannot pin the Mac awake.
- **A separate receiver was rejected.** A LaunchAgent that listens without the
  app would be a second process to sign, update and explain, and it would still
  need the app for pairing, the engine hand-off and the Local Network
  permission. Login item + self-healing covers the same ground.

"Why isn't it syncing" has an answer on the Mac: the iPhone pane says whether a
phone can reach this Mac and why not, when each paired phone was last in
contact, and keeps a small rotating `PhoneSync/sync.log` (states, IDs, sizes
and errors; never titles, audio or transcript text) behind **Copy details** and
**Show log**.

### The phone's side of the link (amended 2026-11)

The first version connected the way a script would: every attempt started its
own Bonjour browse (most of a second when the Mac was there, 8 s to learn it
was not), a fixed timer retried, the presence browser ran for as long as the
app lived (through an hour-long background recording), and the only state the
user saw was a dot. A denied Local Network permission read as "open Huske on
your Mac". The phone now supervises the link by events:

- **One browse, and no connect without a Mac.** `MacPresenceMonitor` is the
  only browser. It reports the Mac's endpoint and its own state
  (`MacPresence`), and a pass connects to that endpoint
  (`SyncClient.connect(to:)`). While the Mac is not visible nothing is
  attempted; its appearing is the trigger.
- **Events, then a clock.** The Mac appearing or being seen another way, a
  network path change and the app coming to the front each start a pass at
  once. Only a failure with the Mac still visible is retried on a clock (2 s
  doubling to 60 s, with jitter), and each event resets it. A key the Mac
  refuses is never retried on a clock.
- **Looking is paid for in battery.** The browse and the path monitor run only
  while the app is on screen or a pass is running. A background pass starts
  the browse, waits up to 8 s for the Mac, and stops it afterwards.
- **A path that is still coming up gets a moment.** A connection that hits a
  *path* error while connecting is given about 3 s (Network.framework retries
  on its own when the path changes); a refused port or a rejected key fails at
  once. To see a rejection at all the client connects to the address behind
  the Bonjour service: Network.framework keeps a connection to a *service*
  endpoint "preparing" after a TLS rejection, which read as a timeout.
- **One typed state for the UI.** `LinkState` — Local Network off, not on
  Wi-Fi, the Mac refused this iPhone, looking, nearby, connecting, connected
  (over Wi-Fi or directly), trying again in N s — is drawn as a glyph and plain
  words on the Mac screen and in the home header, with the way out where there
  is one (Open Settings, Scan Pairing Code).
- **Copy details.** The phone keeps its last 200 sync events (states, attempts,
  errors, sizes, timings; never audio, transcript text, titles or names) and
  can copy them, as the Mac can.
- **A pairing is replaced only by one that works.** With a Mac paired, a new
  code is a candidate until its Mac answers. A code the Mac no longer accepts
  must not cost the pairing the user has.

Rejected: keeping the browser running in the background (it would see the Mac
sooner, at the price of peer-to-peer browsing through every long recording),
and a "reachability" ping of our own (Bonjour already says when the Mac is
there, and a connection is the only honest test of the rest).

### Pairing security and throughput (amended 2026-11)

The pairing link was the key, for good: a QR code on a screen and a string on
a clipboard, valid until the device was removed on the Mac, and nothing on the
phone could remove it there. Three additive changes close that, each used only
between two apps that both have it (`capabilities`, or a field an older peer
ignores), so today's iPhone build keeps working with the new Mac and the
reverse:

- **The link's key is replaced right after pairing** (`pairing.rekey`). The
  phone asks over the paired connection, the Mac hands it a new credential,
  the phone stores it and proves it on a second connection, and with that
  `hello` the Mac retires the link's key — about a third of a second after
  pairing. Two properties were worth their cost:
  - *It cannot lock a phone out.* The Mac accepts both keys until it has seen
    the new one used; the phone keeps both until the Mac has answered the new
    one, tries the new one first, and never drops a key on its own judgement
    (a connection that drops before `welcome` is indistinguishable from a
    refusal). Every interruption point — a lost answer either way, either app
    quitting between two steps, a Keychain that refuses, an older app on
    either side, the registry rewritten by an older Huske.app — has a test,
    on both ends.
  - *It does not wait for a recording.* A pass with nothing to send does not
    connect, so a rotation cut short (the Mac killed between issuing the key
    and seeing it used, found end to end) used to finish only at the next
    recording, with the link's key valid until then. A rotation still owed
    now counts as work while the Mac is visible; a Mac that does not rotate
    keys, and a pairing it refused, are not contacted for it.
  - *The new key does not travel under the old one alone.* TLS-PSK has no
    forward secrecy, and the key being replaced is the one that may have
    leaked, so the new key is sealed to an ephemeral X25519 exchange. A copy
    of the link plus a capture of the whole pairing still yields nothing.
- **How one device has two keys.** A running listener cannot be given a key
  (replacing it takes the Bonjour advert down for a second), and one PSK
  identity cannot have two. So the new credential is one of the spare slots
  the listener already carries, *identity included*: rotation changes the
  phone's device ID. The Mac records it on the device as a `successor` the
  handshake also accepts, and promotes it in one registry write. Rejected:
  keeping the device ID and adding a separate "PSK identity" field — an older
  build of either app reading that record would present or expect the wrong
  identity, where a plain `{deviceID, key}` reads the same to every version.
- **The spare slots no longer run out.** A pairing now takes two, so the pool
  went from 8 to 64, and it is refilled (by replacing the listener) below 16
  only at a quiet moment: nothing connected, nothing for a minute, no pairing
  code waiting. The advert used to drop at every ninth invite.
- **"Forget this Mac" tells the Mac** (`pairing.unpair`) when the Mac is
  nearby; the phone forgets first either way. When it is not, the Mac keeps
  its entry and its Remove button — an unreachable Mac cannot be told, and a
  queued goodbye would need the key the user just asked to forget.
- **A phone that pairs again replaces its earlier entry** (`hello.installID`).
  The ID is random, kept in the iPhone's Keychain for this device only: it
  survives re-pairing, forgetting and reinstalling on the same iPhone (the
  cases that used to leave a second entry with a working key) and does not
  follow a backup or transfer to another iPhone (which is another phone, and
  must not displace the first). The Mac drops an install's other entries when
  a `hello` names it, so the phone names it only with the pairing it has
  stored — never while trying a new code next to one that works. Entries
  without an ID keep the "looks like an earlier pairing" hint.

Two things on the same path were fixed with it:

- **Network or file.** `SyncError.io` covered both a refused connection and
  an unreadable recording, and the phone told them apart by checking whether
  the file was there. The network has its own case now (`.network`: refused,
  no route, name not resolved), so a refused connection reads "… isn't
  accepting connections — open Huske on your Mac" and an unreadable file
  fails that one recording instead of ending the pass.
- **Chunks follow the link.** One chunk, one acknowledgement: at a fixed
  256 KiB a two-hour recording (58 MB) took about 14 s through 25 ms of
  latency each way. Chunks now double up to the 1 MiB frame limit while they
  are acknowledged within a second and halve when one takes over five: about
  4 s (222 round trips → 57). The Mac always accepted 1 MiB, so no capability.
  Pipelining a window would be faster still; it would also break "one
  request, one reply", and with it the simple resume and error handling the
  fault tests pin. Not worth it at these sizes.

Considered and left out: finishing a long upload after the user leaves the
app with `BGContinuedProcessingTask` (iOS 26). The upload already gets about
30 s of background time and resumes where it stopped; with larger chunks the
case it would help — over a minute of upload on a slow link — is rarer still.
Against that, checked on 2026-11-21 with a throwaway probe app: in the iOS 27
simulator `register(forTaskWithIdentifier:)` for a continued-processing
identifier returns false (with and without the `processing` background mode),
and a `submit` after a refused registration raises an Objective-C exception —
which Swift's `try` does not catch — and aborts the app. CI's iOS 18.5 SDK
cannot compile the API at all. So the code would ship without having run
anywhere, on the path where a recording stops, where a mistake costs a crash
rather than a slower upload; and each upload it covered would show a system
progress notice besides. Revisit with a device in the loop.

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

- Phone sync requires Huske.app to be running; with the app closed, the phone
  queues and retries. Open at login is opt-in and offered once a phone is paired
  ("Staying reachable").
- Between two current apps a phone that pairs again replaces its earlier
  entry, "Forget this Mac" removes it on the Mac, and the pairing link stops
  working once used ("Pairing security and throughput"). With an older app on
  either side none of that happens, as before: every pairing mints a new
  device ID and key, the earlier entry stays paired with a key that still
  works, and the link stays valid. The Mac never revokes a key by guesswork
  (two iPhones can share a name and model); it says an entry "looks like an
  earlier pairing" only when a newer one has the same name and model *and*
  the older has been silent ever since, and offers Remove.
- A new local-network surface: Huske.app accepts TLS-PSK connections only from
  phones the user paired, and can forget a device at any time. `Info.plist`
  gains `NSLocalNetworkUsageDescription` + `NSBonjourServices`.
- Releasing the iPhone app needs an Apple Developer team for signing; the
  project builds unsigned for the simulator.
