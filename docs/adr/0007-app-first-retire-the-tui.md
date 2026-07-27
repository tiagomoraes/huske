# ADR 0007 — App-first: retire the Rich terminal panel

- Status: accepted
- Date: 2026-07-21
- Relates to: ADR 0006 (native macOS app)

## Context

huske started as a terminal app: `huske run` rendered a Rich Live panel
(meters, countdown, event log) with single-key runtime controls, and
`--no-ui` swapped it for plain stdout. ADR 0006 then added Huske.app as a
second head over the same engine via `--control-socket`.

Maintaining two interactive UIs for one engine costs real work: every session
feature (screenshots, distillation, device switching, warnings) needed a
panel rendering, a key binding, an overlay state machine, *and* an app
surface. The panel also fought the engine's real deployment shapes — under a
LaunchAgent or the app there is no TTY, so the TUI code paths were already
dead in the two most common ways huske runs.

## Decision

Huske.app is the one interactive UI. The Python engine is headless:

- `huske/ui/` (Rich Live panel + terminal key reader) is deleted. `huske run`
  prints plain progress lines and structured console logs, always.
- `RenderState` stays — it is the live session state that
  `build_control_snapshot()` serializes onto the control socket for the app
  and the menu bar helper. Only its TUI-only fields (help overlay, input
  picker) were removed.
- `--no-ui` remains as a **hidden no-op** so existing launchers keep working:
  the app itself passes it (older engines would otherwise render Rich frames
  into the app's log pipe), and pre-0007 LaunchAgent plists include it.
  `no_ui` stays accepted in config files for the same reason.
- The macOS **menu bar helper** (`huske menubar`) stays: it is the UI for
  terminal/LaunchAgent sessions and costs one small optional process.
- `huske autostart` (LaunchAgent) stays for app-less setups. The everyday
  autostart is now the app's *Open at login* + *Start recording when Huske
  opens* toggles (SMAppService).
- `rich` remains a dependency for now — `huske doctor` and the update-check
  banner print through it. Console output, not a UI.

## Consequences

- Terminal sessions lose the live panel and single-key controls; they keep
  plain progress lines, Ctrl+C graceful stop, and the menu bar item. The
  interactive equivalents live in Huske.app (including a ⌘K palette).
- One presentation surface to keep correct; session features are implemented
  once against the control protocol (protocol.py ↔ ControlProtocol.swift).
- The engine's stdout is now stable, grep-friendly output in every mode —
  what the app's launch-status tail and the LaunchAgent logs already assumed.
- Docs, website, and the CLI contract change from "terminal app with an
  optional Mac app" to "Mac app over a headless engine".
