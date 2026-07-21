# Huske.app

Native macOS app for [huske](../README.md) — a SwiftUI shell over the same
Python engine the terminal UI drives. No pipeline logic lives here; the app
supervises `huske run` over its control socket and shells out to the CLI for
everything else. Architecture: [ADR 0006](../docs/adr/0006-native-macos-app.md).
User/contributor docs: [docs/macos-app.md](../docs/macos-app.md).

```bash
swift test                # unit tests (HuskeKit)
./scripts/build-app.sh    # → dist/Huske.app
open dist/Huske.app
```

Development:

```bash
HUSKE_APP_DEMO=1 swift run Huske                    # scripted fake session
swift run Huske --render-screens /tmp/screens      # offscreen UI renders
HUSKE_INTEROP_PYTHON=../.venv/bin/python swift test --filter PythonInterop
```

Layout:

- `Sources/HuskeKit/` — engine-facing library: control-protocol codec, Unix
  socket client, process supervisor, session state machine, transcript
  contract parser, CLI bridges (config / doctor / devices), meter math.
- `Sources/Huske/` — the app: Record, Transcripts, Doctor, Configuration,
  menu bar extra, onboarding.
- `Tests/HuskeKitTests/` — XCTests, including the cross-language interop test
  against the real Python `ControlServer`.
