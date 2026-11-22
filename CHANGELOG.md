# Changelog

All notable changes to huske will be documented in this file.

This project uses semantic versioning after the first public release.

## Unreleased

### Fixed

- **An engine no longer refuses to start over a config key it doesn't
  know.** Several engines (a uv tool, a Homebrew keg, a checkout) share one
  `~/.config/huske/config.toml` and upgrade at different times; a key written
  by a newer or different one (e.g. `diarize`) used to stop the others cold.
  Unknown keys in the file are now ignored with a one-line warning naming
  them; `huske config set` still rejects typos.
- **`keep_audio = true` in the config file is honored by `huske run`.** The
  run command's `--keep-audio` flag defaulted to off and silently overrode the
  config, so chunk audio was deleted anyway.
- **Remote voices no longer show up twice when you're on speakers.** The
  meeting audio your speakers play leaks into the microphone. Huske used to
  only *attenuate* that leak, and the attenuated copy still transcribed, so
  remote lines kept reappearing as `mic` lines. Huske now *cancels* it with
  WebRTC AEC3, the echo canceller Chrome and Meet use, against the clean system
  channel before transcription. On a MacBook Pro's own speakers and mic, a
  remote monologue that the old suppressor still let through word for word
  (55 of 55 words) now leaks 2. Your own voice is kept, even
  when both sides talk at once, and with headphones nothing changes.
  - **Mic and system now share one clock.** Both are recorded from one Core
    Audio aggregate device, so they stay sample-aligned for the whole session.
    Before, an underrun could permanently shift the system channel later than
    the mic, which also skewed the `system` timestamps in transcripts.
  - **New config keys.** `echo_canceller = auto | webrtc | coherence` and
    `capture_sync` (both on by default). If the aggregate cannot be built,
    capture falls back to independent streams, and the canceller still
    re-aligns them.
  - See `docs/adr/0012-webrtc-aec3-and-single-clock-capture.md`.

- **"Your huske engine needs an update" with no way out.** An engine that
  cannot *run* — most often a checkout whose virtualenv was rebuilt, leaving a
  console script whose `#!` interpreter no longer exists — rendered as an
  engine that was merely old, and the upgrade button on that screen offered
  `uv tool upgrade huske` for an engine uv had never seen. That command exits 0
  after upgrading a *different* install, so the screen never changed: an update
  prompt with no reachable end. Huske now tells "won't run" apart from "too
  old", names the interpreter that actually went missing, and leads with the
  working engines already on the Mac. The upgrade button appears only when a
  package manager owns the engine in use, and an upgrade that finishes without
  moving that engine now says so instead of looking like nothing happened.
- **A pinned engine that vanished showed the first-run welcome screen** —
  "Huske needs its recording engine", on a Mac with two working engines
  installed. A pin that stopped resolving is a repair, not an onboarding.
- **Recording controls reflect the real reason they're off.** The transport
  dock, ⌘K palette, and ⌘R menu item gate on "the engine is usable", not on
  "the engine is old", and the dock's tooltip names which of the two it is.
- **A phone recording's transcription could hang for hours.** Huske.app read
  a command's output and then its errors, one after the other. `huske inbox
  process` sends everything its transcriber prints (a first model download's
  progress bars, for one) to the error stream and prints its result only at
  the end, so once more than 64 KB of messages piled up, both sides waited on
  each other until a 6-hour watchdog killed the transcription. The app now
  reads both streams at once.
- **Starting a recording no longer runs two transcription models at once.**
  If you started a meeting while Huske was still transcribing a phone
  recording, the phone pass kept its own model loaded next to the meeting's
  until it had worked through the whole queue. It now hands the queue to the
  recording session within about a second: the recording it was on goes back
  to "queued" without using up a retry, and the session transcribes it.
- **A phone recording that failed can be tried again from the Mac.** After
  three failed attempts (say, the first one ran offline before the model was
  downloaded) a recording stayed "Couldn't transcribe" for good: the iPhone's
  Retry only re-sends audio the Mac already has, and the Mac offered nothing
  short of `huske inbox retry` in a terminal. The iPhone pane now has
  **Try again** on those rows.
- **A transcription pass that died no longer stops phone recordings from
  being transcribed until Huske is relaunched.** If the background pass that
  transcribes phone recordings was stopped mid-recording, its transcriber kept
  running for nobody at full CPU and kept the app waiting for it, so no later
  recording was ever started and the phone showed "Transcribing · 1 of 3" for
  good. Three things changed:
  - The transcriber now exits within about a second when the process that
    started it is gone.
  - A pass that is told to stop puts its recording back in the queue without
    using up one of its three attempts.
  - The app stops the whole group of processes on a timeout, and no longer
    waits on output that only a leftover process still holds.
- **Your iPhone keeps finding your Mac with Wi-Fi switched off.** With Wi-Fi
  off in Control Center, the iPhone can still reach the Mac directly
  (peer-to-peer). But it lost sight of it after a few seconds, and a
  recording saved then sat on "Waiting for your Mac". Now, while Huske is
  open or a recording is on its way, the iPhone looks for the Mac again
  every 15 seconds while it can't see it. A recording that just stopped
  also looks for a few seconds before it waits.
- **The Mac no longer drops out of your iPhone's reach until Huske is
  relaunched.** If the part of Huske that listens for the iPhone failed, it
  stayed down while the pane still said "Ready". It now restarts itself (after
  1 s, then 2, 4 … up to 30), and it only says your iPhone can reach the Mac
  once the system has confirmed that the Mac is announced on the network. If
  that announcement never appears or is withdrawn, Huske announces again. After
  the Mac wakes or the network changes, it checks that it can still be found
  and repairs it right away.
- **Huske listens for your iPhone even when it opens without a window.**
  Start-up ran only from the main window. Opened at login, or with the window
  closed the last time you quit, Huske sat in the menu bar doing nothing: no
  phone sync, and "Start recording when Huske opens" did not start. It now
  starts when the app launches.
- **A recording that stopped arriving no longer says "Receiving" for ever.**
  If the iPhone walked away mid-upload, or Huske was relaunched, the row stayed
  at "Receiving · 42%" and the menu bar kept saying a recording was arriving.
  The row now reads "Waiting for iPhone · 42%" until the phone resumes, and it
  goes away if the Mac no longer holds that upload.
- **Retry on the iPhone reaches the Mac.** When the iPhone offers a recording
  again that the Mac had given up on, the Mac now queues it for another try,
  the same as **Try again** in the iPhone pane. Before, it answered "already
  have it" and the recording stayed failed.
- **A recording that keeps failing says so in about a minute.** Each new
  attempt waited two minutes for its turn, so a recording that could not be
  transcribed took three and a half minutes to show "Couldn't transcribe" on
  the phone. A recording waiting to be retried now gets its next attempt
  within about 20 seconds.
- **Sending a recording no longer times out when the engine is slow to
  start.** The Mac answered the iPhone only after handing the recording to the
  transcriber, and the phone stops waiting after 30 seconds. The Mac now
  answers as soon as the recording is safely on its disk and hands it over
  right after.
- **An iPhone that pairs again no longer leaves a silent duplicate.** Pairing
  again (after "Forget this Mac", say) used to add a new entry while the old
  one stayed paired, with a key that still worked. With both apps updated, the
  Mac now recognises the same install of the iPhone app and replaces the
  earlier entry by itself, once the new pairing is confirmed (trying a new code
  never costs the pairing that works). With an older iPhone app the iPhone
  pane points out the old entry as what looks like an earlier pairing, not
  used since, next to **Remove**, and leaves it to you: two different iPhones
  can have the same name and model.
- **The Mac no longer drops off your iPhone's radar every ninth pairing
  code.** Huske kept eight spare keys ready for pairing codes; the ninth
  restarted the part that listens for the iPhone, and every iPhone watching
  saw the Mac vanish for a moment. It now keeps 64 and tops them up only when
  nothing is connected, nothing has happened for a minute and no code is
  waiting to be scanned.
- **"Isn't accepting connections" when Huske on the Mac isn't open.** A Mac
  that turned the connection away read on the iPhone as "Couldn't send a
  recording: network error…", and a network drop during an upload marked
  that recording failed, then the next one. The iPhone now says "*Mac* isn't
  accepting connections — open Huske on your Mac", and a network problem
  never marks a recording failed: it ends the sync and is tried again. Only a
  recording whose audio really can't be read on the iPhone fails, on its own,
  and the others still go out.
- **A session that crashed no longer holds up phone recordings.** A crashed
  `huske run` leaves a lock file with its process ID. When macOS later gave
  that ID to another program, Huske took the dead session for a live one:
  recordings from the iPhone waited, and the crashed session's audio was not
  recovered, until the next `huske run`. Huske now also checks that the
  program is older than the lock.
- **A recording tried again on the Mac shows up on the iPhone.** After **Try
  again** in the Mac's iPhone pane, the phone kept saying "Couldn't
  transcribe": it had stopped asking about that recording. It now asks once
  each time you open the app, and brings the transcript back.
- **Stopping Huske while it decodes a phone recording no longer counts as a
  failed attempt.** The stop also ended the audio converter, which looked like
  a file that could not be decoded. The recording now goes back in the queue
  with its three attempts intact.

### Added

- **Huske for iPhone: record anywhere, transcribe on your Mac.** A new iPhone
  app (`ios/`) is a simple recorder with Voice Memos ergonomics. It keeps
  recording in the background, with a Live Activity on the Lock Screen and in
  the Dynamic Island that has pause/resume and stop buttons. When a recording
  stops, it syncs to *your* Mac and enters the normal transcription queue there.
  The transcript then comes back and is readable on the phone. No cloud, no
  account.
  - **Pairing** is one QR code: *Huske.app → iPhone → Pair iPhone*, then point
    the iPhone camera at it.
  - **Transfer** is direct and encrypted (TLS with a per-phone key) over your
    Wi-Fi, or over peer-to-peer Wi-Fi when the two devices are merely near each
    other. It is resumable, and idempotent, so nothing is transcribed twice.
  - **On the Mac**, the new **iPhone** pane lists paired phones and each
    recording's progress (receiving → queued → transcribing → transcribed).
  - Phone transcripts are ordinary transcripts, tagged `origin: phone`,
    `device`, `title`.
  - **Action button and Control Center.** The *Huske Record* control starts a
    recording without opening the app, the way Voice Memos does; the next
    press stops and saves it.
  - **Shortcuts and Siri.** Start (optionally named), Start or Stop, Stop,
    Pause or Resume, Get Latest Transcript, Get Transcript (plain text or
    Markdown with timecodes), Open Recording and Find Recordings. Requires
    iOS 18.
  - See `docs/adr/0011-iphone-recorder-and-mac-sync.md` and
    `specs/002-phone-sync/`.
- **"Why isn't it syncing?" has an answer on the Mac.** The iPhone pane says
  whether your iPhone can reach this Mac right now and, when it can't, why and
  what to do (for example, turn on Local Network access for Huske). Each paired
  iPhone shows "Connected" or when it was last seen.
  - **Copy details** copies that state with the recent sync log, and **Show
    log** opens the log in the Finder. The log is small (under 400 KB) and
    holds states, recording IDs, sizes and errors. It never holds titles, audio
    or transcript text.
- **The iPhone reconnects the moment your Mac is back, and says why when it
  can't.** Instead of retrying on a timer, the iPhone app reconnects when your
  Mac reappears on the network, when the network changes or when you open the
  app, and it doesn't try while the Mac isn't there. It looks for the Mac only
  while the app is open or a sync is running, which saves battery during long
  recordings. The Mac screen shows the link in plain words (Local Network off,
  looking for your Mac, connected over Wi-Fi or directly, retrying in a few
  seconds) with the way out, and **Copy details** copies a short sync log.
  - **A rejected or stale pairing code no longer breaks a working pairing.**
    A new code replaces the old pairing only after the Mac accepts it, and a
    code the Mac refuses says so at once instead of timing out.
  - **Retry works end to end.** "Couldn't send — Retry" sends again, and Retry
    on a recording your Mac couldn't transcribe asks the Mac to try again.
    Deleting a recording stops its upload.
- **A pairing code stops working once your iPhone has used it.** The QR code
  (or the copied link) used to be the iPhone's key for good: anyone who kept a
  copy — clipboard history, a forwarded screenshot — could connect as that
  iPhone. Right after pairing, the two apps now swap it for a key that never
  leaves the two devices (sent sealed, so even a recording of the exchange
  plus the code doesn't reveal it), and the code's key stops working.
  - There is nothing to do. It takes a fraction of a second; a swap that is
    interrupted (the Mac quits halfway, the connection drops) finishes the
    next time the iPhone sees the Mac, and the iPhone always keeps a key the
    Mac accepts.
  - A pairing made before this is swapped the first time both apps are
    updated, without pairing again.
- **"Forget this Mac" on the iPhone also removes the iPhone on the Mac**, when
  the Mac is nearby. When it isn't, the iPhone forgets it anyway and the Mac
  lists the iPhone until you remove it there.
  - This and the two items above need the new version on both devices; with an
    older app on either side, pairing works exactly as before.
- **Name your Mac on the iPhone.** Two Macs that both call themselves
  "MacBook Pro" can be told apart. Under **Mac** on the iPhone, type a name
  such as "Office" in **Name**. Only this iPhone uses it, and the Mac's own
  name stays visible underneath. Pairing the same Mac again keeps the name.
  Clear the field to go back to the Mac's own name.
- **Uploads are faster on slow links.** Each piece of a recording waits for
  the Mac's answer before the next is sent, so on a slow link most of the time
  went to waiting. The iPhone now sends larger pieces (up to 1 MB) while the
  link keeps up and smaller ones when it doesn't: a two-hour recording (58 MB)
  over a link with 25 ms of delay each way takes about 4 s instead of 14. It
  works with older versions of Huske.app too.
- **The Mac's iPhone pane says how much of a failed recording was
  transcribed**: "Partly transcribed · 2 of 3 parts" rather than "Couldn't
  transcribe", when the parts that worked can be read.
- **An offer to open Huske at login once an iPhone is paired.** Your iPhone can
  only send recordings while Huske is running. After pairing, Huske offers to
  open at login. It never turns this on by itself, and it stops asking once it
  is on or you say no.
- **A long recording shows progress inside each part.** A recording split
  into parts showed "Transcribing · 1 of 3" for the several minutes each part
  takes, which looked stuck. The percentage now moves within a part too. It is
  an estimate from how fast this Mac transcribed earlier recordings, so it
  first appears after one recording has been transcribed.
- **A long recording that fails partway keeps what it got.** Long recordings
  are transcribed in parts. When one part could not be transcribed, the whole
  recording used to show "Couldn't transcribe" and the finished parts never
  reached the phone. Now the other parts are still transcribed, and the iPhone
  shows them with a note: "Part of this recording couldn't be transcribed — 2
  of 3 parts are below." **Retry** is still there, and it transcribes only the
  missing part before the whole transcript replaces the partial one. The same
  goes for `huske inbox retry` and for Huske's own retries. `status.json`
  lists the missing parts in `missing_chunks`. The iPhone app and Huske.app
  both need this version; with an older one on either side a failed recording
  looks as it did before.
- **"Trying again on your Mac" says which attempt it is.** The Mac now tells
  the iPhone that it will retry, and which attempt comes next ("attempt 2 of
  3"), as data. The phone used to work it out from the wording of the Mac's
  status text, which it still does with an older Huske.app.
- **The Mac stays awake while a recording from your iPhone is on its way.** It
  does not go to sleep on its own while a recording is arriving, being handed
  to the transcriber, or being transcribed by Huske's own background pass. It
  goes back to normal as soon as that is done, and also if the iPhone walks
  away mid-upload.
- **`huske import FILE…`** transcribes any audio file (m4a, caf, wav, flac,
  mp3, …) into ordinary transcripts dated from the recording.
  - It goes through a new engine inbox (`inbox_root`, default `~/huske/inbox`;
    `huske inbox add|process|status|retry`). A running `huske run` picks inbox
    items up with its own worker, so no second model is loaded; otherwise a
    one-shot process transcribes them.
  - AAC is decoded with macOS's built-in `afconvert`, so there is still no
    ffmpeg dependency.
- **`huske echo-test`** plays a short phrase on your speakers and reports how
  much of the bleed into the mic the echo canceller removes on *your* hardware.
  Nothing is saved.
- **Huske.app is signed with a Developer ID certificate and notarized by
  Apple.** It opens straight from the download — no right-click → Open, no
  System Settings → "Open Anyway". The ticket is stapled to the bundle, so a
  first launch works offline. Releases sign and notarize in CI when the Apple
  credentials are configured and fall back to the previous ad-hoc build when
  they are not, so forks still build. Local builds sign with a Developer ID
  identity if the keychain has one, ad-hoc otherwise, and both now apply the
  hardened runtime plus `macos/Huske.entitlements` — under the hardened
  runtime TCC denies the engine's microphone *without prompting* unless the
  responsible app carries `com.apple.security.device.audio-input`. See
  `docs/adr/0010-developer-id-signing-and-notarization.md`.
  **Upgrading from an ad-hoc build asks for Microphone and audio-capture
  permission one more time** — the app's identity changed, so macOS re-asks.
  After that the grants finally survive updates, which they never did under
  ad-hoc signing.
- **The app notices new versions.** *Huske → Check for Updates…*, plus a
  once-a-day background check that shows a quiet `Update vX.Y.Z` chip under the
  nav rail, linking to the release. It asks GitHub for one release's version
  number and sends nothing — no audio, transcript, or identifier. Off with the
  Settings toggle, or with `HUSKE_NO_UPDATE_CHECK=1`, which already silenced
  the engine's PyPI banner and now covers both. The engine has warned about its
  own updates since it shipped, but only on a TTY, which an app user never
  sees.
- **An engine picker in Settings (⌘,).** Every `huske` found on the Mac, with
  its version, where it came from, and which one is in use — switch with one
  click, or drop the pin and go back to "newest wins". A stale Homebrew keg
  quietly shadowing a fresh uv tool is now visible instead of inferred.
- **A "checking the huske engine…" state**, so switching engines or hitting
  Check Again no longer flashes the idle screen on its way to the answer.

## 0.14.0 - 2026-08-16

### Changed

- **Lower peak RAM on long sessions.** Acoustic echo suppression now
  processes 8-second windows instead of the whole chunk (a 30-minute dual
  source file no longer allocates multi-GB STFTs). Parakeet converts only the
  current 120 s slice to Metal. WAV load and `--keep-audio` transcode stream
  in blocks. The ASR and distill children cap the MLX buffer cache (512 MB /
  256 MB) and never raise mlx-lm's `wired_limit` (which pinned ~14 GB on an
  18 GB M3 Pro). After two idle minutes the ASR/LLM *process* exits so macOS
  can reclaim the Metal heap; the parent respawns on the next job.
- **One Metal model at a time.** Distillation waits until transcription is
  idle, and a new chunk preempts the next LLM passage. ASR stays the
  priority so recording never shares unified memory with the distill model.
- **Safer defaults.** `chunk_minutes` is now 15 (was 30). Idle unload still
  defaults on; `recycle_idle_process`, `metal_cache_limit_mb`, and
  `metal_memory_limit_mb` are the new footprint knobs. Huske.app shows
  per-process RSS, recommends `large-v3-turbo` when Whisper is pinning a
  language, and recycles `seenEventIDs` with the event log.
- **Distillation is now a tiny ASR corrector.** The opt-in local LLM
  (default `mlx-community/Qwen3.5-0.8B-4bit`, ~0.6 GB) fixes typos and
  obvious mishears in each transcript run instead of extracting statements
  with a 4B model. The raw snapshot stays in `<name>.asr.txt` (not synced);
  the canonical `.md` is rewritten in place. 2B / 4B remain selectable.

## 0.13.0 - 2026-07-31

### Added

- **Private Git transcript sync in Huske.app.** The new Cloud sync pane accepts
  a repository and branch, runs the initial reconciliation, and can publish
  every finalized transcript automatically. The base engine gains `huske sync`
  and a provider boundary whose first implementation is Git. It copies only
  canonical `YYYY-MM-DD/*.md` transcripts into a managed checkout, pulls/rebases
  before committing, uses the user's SSH agent or Git credential helper, and
  treats Git commits as the durable offline retry queue.
- **`services/huske_mcp`: a separate always-on Linux/VPS distribution.** It
  pulls the private repository read-only, incrementally indexes transcripts by
  SHA-256 into SQLite WAL, and serves authenticated stateless Streamable HTTP
  MCP with `overview`, `recap`, `search`, `fetch`, and `sync_status`. Polling is
  the reconciliation path; an optional HMAC-verified GitHub webhook only wakes
  the poller.
- **A 512 MB service profile.** The default `tiny` profile uses FTS5, one
  process, one poll thread, an 8 MB SQLite cache, and a 32 MB mmap ceiling with
  no resident model. The optional `semantic` extra adds Model2Vec hybrid
  retrieval for larger VPSes. Docker, systemd resource limits, health checks,
  deploy-key guidance, and a complete VPS guide ship with the service.

### Changed

- The recording app is now only a writer/publisher. Its MCP, OAuth, local
  vector-index, custom HTTP ingest, and off-device server responsibilities move
  behind the independent service boundary in ADR 0009.
- Local distillation remains an opt-in Statement-sidecar/export feature. The
  remote service deliberately derives its own index from canonical Markdown;
  sidecars are not part of the Git sync contract.

### Removed

- `huske index`, `huske mcp`, `huske setup`, `huske connect`, and `huske serve`,
  along with the `mcp`/`server` extras, embed worker, OAuth connector, local
  sqlite-vec stores, ingest endpoint, and their app supervision UI.

### Security

- `huske-mcp` refuses to start without a bearer token even on loopback,
  validates MCP Host/Origin values, bounds request and transcript sizes, keeps
  the Git checkout read-only, and never exposes repository credentials through
  MCP status or its public health response.

## 0.12.0 - 2026-07-28

### Changed

- **Ruff and mypy are CI gates now**, not conventions. Both were already clean;
  they were just never enforced, so "clean" depended on whoever remembered to
  run them. The new `Lint & types` job runs `ruff check .` and `mypy huske`.
  The two `@mcp.tool()` ignores gained `unused-ignore` because CI installs only
  `.[dev]` — without the `mcp` extra the decorator reads as untyped and the
  ignore is required, while a machine with the extra sees it as redundant.
- `scripts/update-homebrew-tap.py` retries the pip resolve before giving up.
  It runs minutes after the release publishes, and PyPI's JSON API, simple
  index and file CDN go live at different times — v0.11.1 failed once and
  succeeded a minute later, unchanged. Four attempts, 20 s apart, then a
  message that names propagation as the likely cause.
- `actions/upload-artifact` in CI matches the release workflow (v7); it had
  been left on v4.

### Fixed

- **A latent unpack bug in the built-in distillation backend.** `mlx_lm.load()`
  is typed as returning either `(model, tokenizer)` or
  `(model, tokenizer, config)` and is not overloaded, so the two-value unpack
  could not be narrowed. Runtime was fine — we never pass `return_config` — but
  the code was one keyword argument away from breaking, and no local run caught
  it because an interpreter without `mlx-lm` sees the whole module as `Any`.
  The new mypy gate found it on its first CI run.

### Added

- **huske auto-manages the local Ollama daemon for distillation.** Only relevant
  on `distill_backend = "ollama"` — the default `mlx` backend downloads its own
  model. When distillation turns on, at launch or via the app / menu-bar toggle,
  huske now starts `ollama serve` if the `ollama` CLI is installed but idle, and
  pulls the configured model if it's missing (streaming progress to the events
  log), instead of only warning that the daemon is unreachable. It only ever
  runs the local `ollama` CLI — it never installs Ollama — and still degrades to
  the same actionable hint when it can't help. Opt out with
  `distill_auto_manage = false` or `--no-distill-auto-manage`. The model it
  starts and pulls is the existing, editable `distill_model`.

## 0.11.1 - 2026-07-27

### Fixed

- **Autostart no longer pins the wrong microphone for the whole session.**
  When `huske run` starts before the configured microphone has connected —
  typical for the login LaunchAgent with Bluetooth earbuds, which pair a few
  seconds after login — huske fell back to the default mic and stayed there
  forever, because PortAudio only sees hot-plugged devices after a
  re-initialization. With speech-gated chunking, a fallback mic that hears
  nothing meant no chunk ever opened and the session looked stuck "waiting"
  despite reporting recording. A mic doctor in the run loop now rescans the
  device list every 30 s while on a fallback mic and hot-swaps onto the
  configured device as soon as it appears; it also restarts a mic whose
  stream stopped delivering audio (device vanished after sleep/wake). The
  fallback warning is sticky until the configured device is claimed, so it
  stays visible in Huske.app and the menu bar rather than scrolling past.

- **Huske.app runs the newest engine installed, not the first one it finds.**
  A Mac accumulates engines from different managers — `uv tool` in
  `~/.local/bin`, Homebrew in `/opt/homebrew/bin` — and they upgrade at
  different times. The app probed those locations in a fixed order and took the
  first hit, so a `uv tool` install left at 0.10.0 shadowed a freshly installed
  0.11.0 and the app offered to upgrade the old engine while a current one sat
  one directory away. It now asks each candidate for its version and picks the
  highest (ties by discovery order; an explicit override still wins outright).
  Configuration shows the engine in use and lists any others under "Also
  installed, not in use", so the choice is visible rather than implied.

### Changed

- **The cross-language protocol contract is enforced in CI.** The app is a
  client of the Python engine, so a field added to `huske/ipc/protocol.py` and
  not mirrored in `ControlProtocol.swift` only surfaced at runtime.
  `PythonInteropTests` — which drives the real `ControlServer` with the Swift
  client — skipped unless `HUSKE_INTEROP_PYTHON` was set, and nothing set it, so
  the one test that catches drift never ran. CI now runs it; renaming a single
  wire constant fails the build. The control plane is stdlib-only, so the gate
  needs an interpreter and `PYTHONPATH`, not an install.
- `scripts/update-homebrew-tap.py` exits non-zero when the formula is missing
  resources for new dependencies. `brew style` and `brew audit` both pass in
  that state — only `brew install --build-from-source` catches it — so a green
  exit read as "ready to push" when it was not. v0.11.0 needed six added by
  hand (the `mlx-lm` stack).

## 0.11.0 - 2026-07-27

### Added

- **Transcripts that stay in the language you speak.** Parakeet has no
  language input — it infers one per decode window — and on speech that mixes
  a non-English language with English jargon that guess is unstable enough
  that moving a window boundary by 0.2 s can flip two minutes of Portuguese
  into English. `language` now reaches the Parakeet engine and drives a drift
  guard: a window that collapsed into English is re-decoded as two overlapping
  halves. For a language that must be *guaranteed*, use the Whisper engine,
  whose decoder takes a real language token — `huske doctor` and `huske run`
  now say so instead of letting the setting look enforced. Whisper also gained
  the `large-v3-turbo` model, which is both faster and more accurate than
  `medium`:
  `asr_engine = "whisper"`, `model = "large-v3-turbo"`, `language = "pt"`.
- **⌘K command palette in Huske.app.** Every session and navigation action —
  start/stop/pause, screenshots, distillation, panes, doctor, recovery,
  folders, settings — behind one fuzzy-searchable, keyboard-first palette.
- **Record from the moment you log in.** Huske.app gained *Open Huske at
  login* (an SMAppService login item) and *Start recording when Huske opens*
  — in Configuration → "This app" and in Settings (⌘,). Together they replace
  the LaunchAgent as the everyday autostart (the `huske autostart` LaunchAgent
  remains for app-less, menu-bar-only setups).
- **One-click engine install and upgrade.** Onboarding detects uv or Homebrew
  and installs the engine with a single button, streaming the package
  manager's output into the window; it also notices a terminal-side install
  by itself. The outdated-engine screen upgrades the same way, using
  whichever manager owns the current binary.

- **Built-in distillation — no more Ollama requirement.** `distill_backend`
  now defaults to `"mlx"`: huske runs the distillation LLM itself via
  `mlx-lm` in an isolated subprocess, downloading the default model
  (`mlx-community/Qwen3.5-0.8B-4bit`, ~0.6 GB) from Hugging Face on first
  use — exactly like the Parakeet weights. Nothing to install or keep
  running; the model idle-unloads after ~2 min like the transcribe worker.
  `distill_backend = "ollama"` still delegates to a local daemon, and the
  known Qwen tags (`qwen3.5:0.8b` …) auto-map to their MLX builds so
  existing configs keep working. See the amendment in
  `docs/adr/0005-llm-distillation.md`.

### Changed

- **The transcript browser opens on the newest chunk and stays fast as the
  folder grows.** Days and chunks are ordered newest-first throughout, the
  sidebar renders a page at a time (arrow-key navigation opens pages as it
  walks past them), and a rescan reuses cached per-file verdicts keyed by size
  and mtime — so a refresh reads the one chunk that just landed instead of
  every file on disk. A finished chunk landing at the top no longer yanks a
  reader out of the window they scrolled open.
- The macOS app is fully brand-styled (IBM Plex, hidden title bar, custom
  sidebar) with engine-capability detection for older CLIs, curated model
  pickers in Configuration, pointer cursors, arrow-key transcript
  navigation, and a Dock badge while recording.

- **Native macOS app — now huske's UI.** A SwiftUI app (`macos/`, built with
  `macos/scripts/build-app.sh` → `Huske.app`) over the headless engine:
  start/stop/pause with live mic + system level meters, chunk/queue state and
  a live activity feed, mid-session screenshot and distillation toggles, live
  microphone switching, a day-grouped transcript browser with per-run
  rendering and full-text search, a Doctor pane, an engine-validated
  Configuration editor, a menu bar extra, and crash recovery. It attaches to
  sessions started from a terminal or the login LaunchAgent, and quitting
  while recording drains gracefully like Ctrl+C. See `docs/macos-app.md` and
  `docs/adr/0006-native-macos-app.md`.
- **Richer control protocol (v2) for external UIs.** `huske run` gained
  `--control-socket PATH` to serve its JSON-line control protocol at an
  explicit socket for an external UI (no bundled menu bar helper). Snapshots
  now carry peak levels, chunk/session timing, warnings, recent events,
  output paths, and the active input device — all backward compatible — and
  clients can switch the microphone (`set_input_device`) and request the
  device list over the socket.
- **`huske config show|set|unset`** — inspect and edit
  `~/.config/huske/config.toml` from the command line with the same
  validation as `huske run` (`--json` output for tooling), and
  **`huske devices [--json]`** — list microphone inputs and how the
  configured one resolves.

- **The transport follows you through the app.** Recording state and its
  controls moved into the sidebar as a persistent dock — status pill, elapsed
  time, and live mic + system meters — so you can watch levels from the
  Transcripts pane and stop from anywhere. The ambient Stop is two-step
  (a stop cannot be undone); the Record console's labelled Stop and ⌘. stay
  single-action. The menu bar mark is now drawn per session state rather than
  a static glyph.
- **Silent chunks no longer become files.** A chunk whose transcription
  produced no text is not written at all, instead of persisting a transcript
  whose whole body is `_(no speech detected)_`. `huske run` reports
  "no speech detected — nothing saved" and `huske recover` skips the chunk.
  Huske.app hides the legacy placeholder files already on disk, so the
  transcript list stops filling with empty days.

### Removed

- **The Rich terminal live panel.** `huske run` is now a headless engine:
  plain progress lines on stdout, with Huske.app and the menu bar item as the
  interactive UIs. The `?`/`p`/`s`/`d`/`i`/`q` keyboard controls went with
  it; `--no-ui` (and the `no_ui` config key) remain as accepted no-ops so
  existing launchers keep working. See
  `docs/adr/0007-app-first-retire-the-tui.md`.

### Fixed

- **The elapsed clock stops when you stop.** It kept counting while the engine
  finalized and drained, so a stop that took a while reported a session longer
  than the recording. The clock now freezes at the moment stop was requested —
  the click for a local stop, the first `stopping` snapshot for one started
  elsewhere.
- **Clicking the Dock icon reopens the window.** After closing the last
  window (the menu bar extra keeps huske alive), a Dock click now brings the
  main window back instead of doing nothing.
- **Hover works again everywhere in the app.** The stateless pointer-cursor
  overlay introduced after the redesign swallowed AppKit mouse tracking, so
  transcript rows, sidebar items, and icon buttons stopped highlighting.
  Hover is now tracked by AppKit itself (cursor rect + tracking area on one
  event-transparent view) and every control got the design-spec hover,
  pressed, and disabled states — including the previously feedback-less
  primary and secondary buttons.

## 0.10.0 - 2026-06-29

### Added

- **Toggle distillation live from the TUI and menu bar.** Distillation no longer
  has to be chosen at launch — press `d` in the live UI's `?` controls overlay,
  or pick **Toggle distillation** from the macOS menu-bar dropdown, to turn it on
  or off for the running session. Turning it on first runs the same readiness
  check as `huske doctor` (local LLM daemon reachable + model pulled) and warns
  with a fix-it hint if it is not ready; both surfaces show the current on/off
  state. The toggle is session-only — set `distill_enabled` in config to make it
  the default.

## 0.9.1 - 2026-06-28

### Fixed

- **Speaker-bleed alignment.** The echo canceller now aligns the mic and system
  channels correctly when the saved system reference arrives *late* relative to
  the mic echo (the two are captured on independent clocks) and when a chunk
  opens with only the local speaker before the first system audio — cases the
  0.9.0 delay estimator missed, leaving the bleed in the transcript. The delay
  search now scans for a jointly-energetic window, allows a negative lag, and
  widens to 2 s.
- **Residual-bleed backstop.** When the mic's transcript of system audio is too
  garbled to match by text, an audio-coherence check now flags and drops the mic
  segment if it is acoustically a copy of the near-simultaneous system channel,
  so bleed no longer survives text de-dup. Your own voice (incoherent with the
  system) is never dropped.

## 0.9.0 - 2026-06-24

### Added

- **Parakeet transcription engine, now the default.** huske transcribes with
  NVIDIA Parakeet (`parakeet-tdt-0.6b-v3`) via `parakeet-mlx` on the Apple
  Silicon GPU. As a transducer it emits nothing on silence/noise instead of
  hallucinating repeated filler ("e aí e aí…", "sports sports…") the way Whisper
  does, and it is multilingual with automatic language detection (~25 languages,
  Portuguese included). The transcription backend is now pluggable
  (`asr_engine = "parakeet" | "whisper"`, default `parakeet`); `--asr-engine
  whisper` keeps the legacy mlx-whisper path, paired with its energy gate.
  Audio is loaded and resampled to 16 kHz with `soundfile` + `soxr`, dropping
  transcription's hidden dependency on the `ffmpeg` CLI.
- **Speech-gated, silence-split segmentation** (`speech_gated`, on by default).
  Chunks now open when speech is first heard and close after a real pause
  (`silence_split_seconds`, default 60 s) or at the `chunk_minutes` cap (now a
  safety cap, default 30 min). Silence between chunks is no longer recorded, so
  a quiet stretch produces no large near-empty file, and a conversation is no
  longer cut mid-sentence at a fixed 15-minute tick. `--no-speech-gated`
  restores the legacy fixed-interval rotation. New flags: `--speech-gated /
  --no-speech-gated`, `--silence-split`.
- **Speaker-bleed removal** when recording mic + system on speakers (no
  headphones), in two stages:
  - **Echo suppression** (`echo_cancel`, default on) — coherence-based
    suppression attenuates the mic content that is coherent with the clean
    system channel (the bleed) before transcription. It is self-gating (no
    coherence with headphones → the mic is untouched) and cannot remove the
    local voice (incoherent with the system), so double-talk is preserved.
    Sample-precise acoustic echo *cancellation* was investigated and simulated
    but is infeasible here: the mic (PortAudio) and system (Core Audio tap) are
    captured on independent clocks, so their alignment jitters and there is no
    stable echo path to subtract (measured negative ERLE on real recordings).
    Coherence suppression is robust to that jitter. `--no-echo-cancel` disables it.
  - **Cross-channel dedup** (`echo_dedup`, default `drop`) — the reliable
    remover: a mic run that echoes a near-simultaneous system run is dropped,
    now matching **partial fragments** (a verbatim chunk of a system line), not
    only whole-line duplicates, via token-set similarity + contiguous-run
    containment + a temporal gate. One-way, so the local voice and the clean
    system line are never removed. `--echo-dedup drop|annotate|off`.

### Changed

- `chunk_minutes` is now a maximum-length safety cap rather than the usual chunk
  boundary, and its default rose from 15 to 30 minutes (see speech-gated
  segmentation above). For speech-gated chunks, `duration_seconds` in the
  frontmatter reports the recorded length and such chunks are no longer flagged
  `incomplete`. The `model` frontmatter value is now e.g.
  `parakeet:tdt-0.6b-v3`. See `specs/001-huske-recorder/contracts/transcript-format.md`.
- The auto-generated `~/huske/transcripts/README.md` was rewritten as a proper
  entry point for an LLM agent: it explains the speech-gated boundaries, the
  corrected frontmatter schema, and what the `mic`/`system` source tags mean
  (you/the room vs. audio played by the computer), with echo removed so system
  audio isn't double-counted on the mic side.

## 0.8.2 - 2026-06-10

### Changed

- `whisper_idle_unload` now defaults to **on**. The transcription worker drops
  the Whisper model after `whisper_idle_unload_seconds` of inactivity (default
  120 s) and reloads it from the local cache on the next chunk, so huske idles
  at a few hundred MB instead of holding ~150 MB (`base`) to ~3 GB (`large-v3`)
  resident through the long gaps between chunks. Recording idles far more than
  it transcribes, and held RAM costs more than a network-free re-read. Pass
  `huske run --no-idle-unload` (or set `whisper_idle_unload = false`) to keep
  the model warm for back-to-back transcription.

## 0.8.1 - 2026-06-10

### Fixed

- Website: the home-page output ledger is now a functional, interactive
  file-tree preview instead of a static block.
- Website: the release history renders Markdown bold correctly instead of
  showing literal `**`.

## 0.8.0 - 2026-06-07

### Added

- LLM distillation into searchable **statements** (opt-in, off by default). A
  local LLM (Ollama; any model tag, default `qwen3.5:0.8b` — the lightest
  portable tier, run non-reasoning) distils each
  transcript into compact, self-contained claims written to a
  `<name>.statements.json` sidecar. With local search enabled, statements are
  embedded into a separate `statements.db`, and `huske mcp` ranks statements
  first — `fetch` returns the matched claim plus the verbatim source transcript
  that grounds it (two-stage retrieval). New `huske distill` backfill, a
  `huske doctor` daemon/model check, and `distill_*` config keys; the send
  transport is dependency-free (loopback HTTP over stdlib). Distillation runs
  off the hot path and degrades gracefully if the daemon is unavailable. See
  `docs/distillation.md` and `docs/adr/0005-llm-distillation.md`.

### Changed

- Screenshots are now smaller on disk by default. The capture interval default
  is `60s` (was `10s`), and each capture is compressed and downscaled in place
  via macOS `sips` (no new dependency, skipped gracefully if `sips` is absent):
  the long edge is clamped to at most `1568px` — Claude's vision target, and it
  never upscales a smaller display — and re-encoded at JPEG quality `60`. New
  `screenshots_max_dimension` / `screenshots_jpeg_quality` config keys and
  `--screenshot-max-dimension` / `--screenshot-quality` flags.
- `keep_audio` now stores compressed audio instead of raw WAV. After a chunk is
  transcribed, its WAV is transcoded to a sibling file and the WAV removed. The
  new `keep_audio_format` config (default `opus`, ~12–20× smaller; `flac` is
  lossless ~2×; `wav` keeps the uncompressed original) drives this via
  `soundfile`/`libsndfile` — no new dependency. Whisper still reads the raw WAV
  first, so transcription is unaffected, and crash recovery is untouched (it
  only handles pre-transcription WAVs).

## 0.7.4 - 2026-06-07

### Added

- Setup guidance for connecting **Claude Desktop and Cowork** to the local
  `huske mcp` server through the `mcp-remote` bridge. Both share one
  `claude_desktop_config.json`, so the same entry exposes huske in Cowork once
  Desktop reloads it. The website home page also gained a quick-start strip that
  surfaces the run-on-login and MCP commands and links to the detailed guides.

### Changed

- Lighter footprint, default-on with no new config. The transcription worker now
  releases the Metal buffer pool after every chunk (not only on idle unload), so
  the per-chunk decode working set is reclaimed during recording gaps even while
  the model stays warm. The ScreenCaptureKit capture stack is now imported
  lazily and loads only when the SCK fallback path actually starts, not on the
  common Core Audio tap path, mic-only mode, or `huske recover`.

### Fixed

- The live UI's "N pending" chunk count was always `0` on macOS: it read
  `multiprocessing.Queue.qsize()`, which raises `NotImplementedError` there. It
  now uses the orchestrator's authoritative pending-chunk count.

## 0.7.3 - 2026-06-03

### Fixed

- The `huske run` startup log now records the running version instead of a
  stale `v0.1.0` placeholder.

### Changed

- The website reads its version from a single source (`website/version.js`),
  and the release tooling now verifies every page matches the released version,
  so the public site no longer drifts to an older version between releases.

## 0.7.2 - 2026-06-03

### Changed

- Website docs page now lives at `/docs/` (clean URL) instead of `/docs.html`.
  In-page nav links no longer expose `index.html` in the URL.

## 0.7.1 - 2026-06-03

### Added

- Idle whisper-model unload (`--idle-unload` / `whisper_idle_unload = true`, off
  by default). The transcription worker drops the model weights after
  `whisper_idle_unload_seconds` of inactivity (default 120 s) and reloads
  lazily on the next chunk, freeing up to ~3 GB of resident RAM during long
  recording gaps. Reloads resolve from a pinned local snapshot directory, so
  they are network-free.
- `--no-menu-bar` (`menu_bar_enabled = false`) now also skips the IPC control
  socket and its accept thread, cutting an additional ~50–80 MB of idle RSS
  when the menu-bar helper is disabled.
- `huske doctor` reports the autostart LaunchAgent state: whether the agent
  is installed, loaded, its running PID, and a pointer to any crash log.
  Informational only; never fails the command; skipped on non-macOS.
- New website docs page covering install, macOS permissions, autostart on
  login, full config reference, and MCP setup for Claude Desktop, Gemini CLI,
  ChatGPT, and other clients.
- `examples/config.toml` now documents every current `RuntimeConfig` key,
  including the new `whisper_idle_unload` and `menu_bar_enabled` footprint
  knobs.

## 0.7.0 - 2026-06-03

### Added

- Off-device replication (opt-in; see
  `docs/adr/0004-off-device-huske-server.md` and `docs/server.md`). `huske serve`
  runs a single-tenant huske server on a box you control (e.g. a VPS): it
  receives finalized transcripts pushed from a recording Mac, stores and indexes
  them with a CPU (`fastembed`) embedder, and serves the existing `search`/`fetch`
  MCP over loopback to a co-located agent. When `sync_endpoint` is configured,
  `huske run` replicates each finalized transcript live — dependency-free and
  off the audio hot path, reconciling after the Mac has been offline — and
  `huske sync` backfills on demand. Only a write-only ingest endpoint is
  network-exposed; the read MCP stays loopback-only. Adds the `huske[server]`
  extra; the send side ships in the base install.
- huske now sets its OS process title via `setproctitle`, so it shows as
  `huske` (and `huske-whisper` / `huske-embed` / `huske-menubar` for its
  worker processes) in Activity Monitor, `ps`, and `top` instead of a bare
  Python interpreter. Best-effort and cosmetic — a silent no-op if
  `setproctitle` is unavailable, and it does not affect macOS privacy
  prompts or the recording indicator.

### Changed

- Python 3.14 is now supported: `requires-python` widened to
  `>=3.11,<3.15`, and the CI test matrix runs against 3.14.

### Changed

- `huske index` now runs **low-impact by default**: the backfill lowers its CPU
  priority, shrinks the embed batch, caps the MLX/Metal buffer cache, and
  releases it between files so indexing a long history can't exhaust RAM or pin
  the GPU. Pass `huske index --fast` (or set `index_low_impact = false`) for the
  previous full-speed behavior. New config knobs `embed_batch_size` and
  `index_memory_limit_mb` tune the footprint further; `embed_batch_size` also
  applies to live indexing during `huske run`.

## 0.6.0 - 2026-06-02

### Changed

- Release process collapses into three scripts under `scripts/`:
  `release.py`, `release-finalize.py`, and `update-homebrew-tap.py`. The
  short operational checklist is `docs/RELEASE_PLAYBOOK.md`;
  `docs/releasing.md` remains as the deep reference.
- `huske/__init__.py` now reads the version from `pyproject.toml` when
  the package source is adjacent (dev checkout / editable install) and
  falls back to `importlib.metadata` for installed wheels. The two
  hardcoded versions could no longer drift the way `0.3.1` had to be
  hotfixed for.

### Added

- `.github/workflows/back-merge.yml` automatically opens the
  `chore/sync-main-after-vX.Y.Z` (or `chore/sync-main-hotfix-…`) PR when
  a `release: v*` / `hotfix:*` PR merges into `main`, so the back-merge
  step no longer relies on the maintainer remembering to open it.
- **Local semantic search** (opt-in `huske[mcp]` extra). `huske index`
  builds or refreshes a local `sqlite-vec` passage store from transcripts.
  Each finalized transcript is embedded via `mlx-embeddings`
  (`multilingual-e5-base`) in an isolated subprocess so the audio drainer
  is never starved. `huske run` can continuously index during recording
  when `indexing_enabled = true` in config. See `docs/adr/0002` and
  `CONTEXT.md` for the Passage model.
- **`huske mcp` daemon** exposes `search` and `fetch` over a loopback HTTP
  MCP endpoint (bearer token + Origin/Host validation). Works with any MCP
  client (Claude Desktop, ChatGPT, etc.). See `docs/adr/0001`.
- `index_root`, `indexing_enabled`, `embedding_model`, `mcp_host`, and
  `mcp_port` config keys for the search subsystem.

## 0.5.0 - 2026-05-09

### Added

- `huske autostart` subcommand group to manage a macOS LaunchAgent that runs
  `huske run --no-ui` at every login. Verbs: `install`, `uninstall`, `status`,
  `start`, `stop`. The plist lives at `~/Library/LaunchAgents/me.huske.plist`
  and stdout/stderr are appended to `~/Library/Logs/huske/agent.{out,err}.log`.
  Default restart policy is "restart on crash only"
  (`KeepAlive={SuccessfulExit:false}`). macOS-only; commands exit with a
  friendly error on other platforms.

## 0.4.0 - 2026-05-09

### Added

- Live UI controls panel. Press `?` in the live UI to open an overlay; inside,
  `p` toggles pause/resume of audio recording, `s` toggles periodic
  screenshots, `q` triggers a graceful stop, and `Esc` closes the overlay.
  Pausing finalizes the current partial chunk and stops writing audio until
  you resume. Toggling screenshots takes effect immediately, using the
  configured screenshots directory and interval. The screenshot interval
  must now be at least 1 second.

### Changed

- Group adjacent transcript segments from the same source under a single
  timestamp range. Long same-source runs are broken up after roughly 90 s so
  monologues do not collapse every interior timestamp, and empty or missing
  source segments are left ungrouped instead of silently merging with
  neighbors.

### Fixed

- Suppress whisper hallucinations on quiet input. Compute a per-source noise
  floor from each chunk's WAV at ingest and drop any segment whose audio
  window sits below an RMS/peak gate calibrated to that floor (with
  conservative absolute lower bounds). Also pass
  `condition_on_previous_text=False` to mlx-whisper so a hallucinated segment
  can no longer anchor the next chunk's decoding. Fails open on WAV read
  errors so a broken file never silently swallows a real transcript.

## 0.3.1 - 2026-05-08

### Fixed

- Corrected the runtime version reported by `huske --version`, `huske doctor`,
  update checks, transcript metadata, and the TUI after the `0.3.0` package
  metadata shipped with `huske.__version__` still set to `0.2.0`.

## 0.3.0 - 2026-05-08

### Changed

- Switched the transcription engine from `faster-whisper` (CTranslate2, CPU
  only on Apple Silicon) to `mlx-whisper` (Apple MLX, runs on the M-series
  GPU). On a Mac this is roughly 5–7× faster and removes the long
  first-load hang we hit with the `small` model. Existing `model` /
  `compute_type` / `device` keys in `~/.config/huske/config.toml` are still
  accepted: model names map to the `mlx-community/whisper-<size>-mlx` repos,
  `compute_type = "float32"` opts out of fp16, and `device` is ignored
  (MLX always runs on the Apple GPU). The transcript `model:` field now
  reads `mlx-whisper:<size>` instead of `faster-whisper:<size>`.
  Apple Silicon only — Intel Macs are no longer supported.
- Added per-source transcript segments for mic and system audio, with system
  WAV padding so segment timestamps map back to the wall-clock session time.

### Added

- Added the Core Audio process-tap backend for system audio capture.
- Optional periodic screenshots. `huske run --screenshots` captures a JPEG
  of every attached display every 10 seconds (`--screenshot-interval`
  configurable, default 10 s). Files land at
  `~/huske/screenshots/YYYY-MM-DD/<session_id>/HHMMSS_dN.jpg` so multimodal
  LLMs can correlate them with the day's transcripts. Capture uses the
  built-in macOS `screencapture` tool — no new Python dependency, and it
  reuses the existing Screen Recording permission. Off by default.

## 0.2.0 - 2026-05-07

### Added

- Update check on startup. Prints a stderr banner when a newer release is on
  PyPI, with the upgrade command tailored to the install method
  (`uv tool upgrade huske`, `pipx upgrade huske`, or `brew upgrade huske`).
  The check is cached for 24 h, runs in a background thread, is silent for
  editable installs and non-TTY stderr, and can be disabled with
  `HUSKE_NO_UPDATE_CHECK=1`.

## 0.1.0

### Added

- Initial always-on macOS terminal recorder.
- Microphone and system audio capture.
- Local transcription through faster-whisper.
- Day-organized Markdown transcript output.
- Recovery for orphaned audio chunks.
- Rich terminal UI and setup doctor.
- Open source project structure: license, contribution guide, code of conduct,
  security policy, support guide, issue templates, PR template, and CI.
