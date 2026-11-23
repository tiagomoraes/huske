# Huske.app

Native macOS app for [huske](../README.md) — the product's UI, a SwiftUI
shell over the headless Python engine. No pipeline logic lives here; the app
supervises `huske run` over its control socket and shells out to the CLI for
everything else. Architecture: [ADR 0006](../docs/adr/0006-native-macos-app.md)
and [ADR 0007](../docs/adr/0007-app-first-retire-the-tui.md).
User/contributor docs: [docs/macos-app.md](../docs/macos-app.md).

```bash
swift test                # unit tests (HuskeKit + HuskeSync)
./scripts/build-app.sh    # → dist/Huske.app
open dist/Huske.app
```

Development:

```bash
HUSKE_APP_DEMO=1 swift run Huske                    # scripted fake session
swift run Huske --render-screens /tmp/screens      # offscreen UI renders
HUSKE_INTEROP_PYTHON=../.venv/bin/python swift test --filter PythonInterop

# Phone sync: narrated end-to-end demo (Bonjour + TLS-PSK + resume); add
# HUSKE_DEMO_ENGINE=/abs/path/to/huske to hand the file to a real engine inbox.
HUSKE_SYNC_DEMO=1 swift test --filter PhoneSyncDemo
# HuskeSync must keep compiling for iOS (the iPhone app in ../ios uses it):
xcodebuild -scheme HuskeSync -destination 'generic/platform=iOS Simulator' build
# Where mDNS is unavailable (some CI runners), skip the Bonjour tests:
HUSKE_SKIP_BONJOUR_TESTS=1 swift test
```

Layout:

- `Sources/HuskeKit/` — engine-facing library: control-protocol codec, Unix
  socket client, process supervisor, session state machine, transcript
  contract parser, CLI bridges (config / doctor / devices), meter math.
- `Sources/HuskeSync/` — phone ↔ Mac sync (macOS + iOS): Bonjour discovery,
  TLS-PSK pairing, framed request/response protocol, resumable sha256-verified
  uploads, the Mac-side `SyncServer` and the iPhone-side `SyncClient`.
  Contracts: `specs/002-phone-sync/contracts/`.
- `Sources/Huske/` — the app: Record, Transcripts, iPhone, Cloud sync,
  Doctor, Configuration, menu bar extra, onboarding. `PhoneSyncCoordinator`
  receives phone recordings and hands them to the engine with
  `huske inbox add`.
- `Tests/HuskeKitTests/` — XCTests, including the cross-language interop test
  against the real Python `ControlServer`.
- `Tests/HuskeSyncTests/` — pairing links, framing, registry, and in-process
  server + client end-to-end tests over loopback and Bonjour.
