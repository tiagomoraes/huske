---
status: accepted
---

# Native macOS app as a shell over the Python engine

## Context

huske has always been a terminal program: `huske run` is a Rich TUI, plus a
small PyObjC menu bar helper spawned over a Unix-domain control socket
(`huske/ipc/`). A native macOS app was requested so huske can be used without
a terminal at all — start/stop/pause, live levels, transcript browsing,
diagnostics, and configuration in a real window.

Two architectures were on the table:

1. **Reimplement the pipeline in Swift** (AVAudioEngine capture, a Swift ASR
   runtime, its own chunker/writer). Full control, no Python dependency at
   runtime — but it forks the product: every pipeline change (speech gating,
   echo dedup, engines, recovery, distillation, sync) would need to land
   twice, and the two implementations would inevitably drift on the transcript
   contract.
2. **Keep one engine, add a second head.** The app supervises the existing
   `huske run` process and renders its state; all recording/transcription
   logic stays in Python.

## Decision

**One engine, two heads.** The app (SwiftPM package in `macos/`, zero
third-party dependencies) drives the Python engine and never re-implements
pipeline logic:

- `huske run --no-ui --control-socket <path>` serves the existing JSON-line
  control protocol at an app-chosen socket path and skips the bundled menu
  bar helper (the app owns presentation). The protocol's `ControlSnapshot`
  grew v2 fields (peak levels, chunk/session timing, warnings, recent events,
  paths, active input device) — all defaulted, so v1 clients/servers still
  interoperate; commands may now carry one argument (`set_input_device`), and
  the server can broadcast a device list on request.
- The app can also **attach** to a session it did not start (TUI or login
  LaunchAgent) by probing `control-*.sock` in the huske Application Support
  directory — the same protocol either way.
- Transcripts are read straight from the on-disk `.md` contract
  (`specs/001-huske-recorder/contracts/transcript-format.md`), the one
  interface that was already promised to stay stable.
- Everything else shells out to the CLI so behavior lives in exactly one
  place: `huske config show/set/unset` (new; Pydantic-validated writes) for
  configuration, `huske doctor --json` for diagnostics, `huske devices
  --json` (new) for device listing, `huske recover` for crash recovery.

The wire contract is pinned on both sides: pytest locks the Python encoder,
XCTest locks the Swift decoder, and an env-gated interop test
(`HUSKE_INTEROP_PYTHON=… swift test --filter PythonInterop`) drives the real
Python `ControlServer` from the Swift client.

## Consequences

- New features surface in the app by extending the snapshot/commands — not by
  porting pipeline code. Snapshot fields are add-only with defaults; existing
  fields are never removed or retyped.
- The app requires the CLI to be installed (uv/pipx/brew). Onboarding detects
  it and explains installation; an explicit binary override is stored in app
  preferences. TCC prompts (microphone, screen/audio capture) attribute to
  the app when it spawns the engine, which is friendlier than terminal-level
  grants.
- The app is versioned with the repo: `macos/scripts/build-app.sh` stamps
  `CFBundleShortVersionString` from `pyproject.toml`, keeping the repo's
  single-source-of-truth version rule.
- Distribution is source-build for now (ad-hoc codesign). Signed/notarized
  distribution is a separate, later decision.

## Amendment (0.11.1) — which engine, and keeping the two in step

Two consequences of "the app is a shell over the CLI" were left implicit and
each produced a real defect.

**Which engine the app drives.** `BinaryLocator` probed `~/.local/bin`, then
`/opt/homebrew/bin`, then `/usr/local/bin`, then `PATH`, and took the first hit.
Position is not a proxy for freshness: a Mac accumulates engines from different
managers that upgrade at different times, so a `uv tool` install left at 0.10.0
shadowed a freshly installed 0.11.0 from Homebrew. The app then feature-probed
the *old* engine and offered to upgrade it while a current one sat one directory
away.

The locator now enumerates every candidate, asks each for `--version`, and picks
the highest, breaking ties by discovery order. An explicit override still wins
outright and is never second-guessed — an explicit-but-broken override resolves
to nothing rather than silently falling back to an engine the user did not
choose. Versions are compared as parsed triples, never as strings (`0.9.0` sorts
above `0.11.0` lexically), and a prerelease sorts below its own release so a
`.dev` build never displaces a shipped engine on version alone.

Version remains a *tie-breaker between candidates*, not a compatibility check:
a dev build cannot be told from a release by its version string, so
`EngineCapabilities` still feature-probes whatever gets picked. Candidates that
lose are shown in Configuration under "Also installed, not in use", because a
silent precedence rule is what made the original bug hard to see.

**Keeping the protocol in step.** The rule "mirror `huske/ipc/protocol.py` in
`ControlProtocol.swift`" was documented but unenforced. `PythonInteropTests`
drives the real `ControlServer` with the Swift client and is exactly the test
that catches drift — but it skips unless `HUSKE_INTEROP_PYTHON` is set, and
nothing set it, so it never ran in CI. Renaming a single wire constant on the
Swift side passed CI green.

CI now sets it. The control plane imports only stdlib (`socket`, `threading`,
`json`, `dataclasses`, `enum`, `queue`), so the job needs an interpreter and
`PYTHONPATH` — no install, no MLX, no dependency resolution — which is why this
gate is affordable enough to keep. Note `Foundation.Process` does not search
`PATH`: `HUSKE_INTEROP_PYTHON` must be an absolute interpreter path.
