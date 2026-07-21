# huske — product context

## Register

**Product.** App UI (native macOS app in `macos/`, terminal TUI) — design serves
the task. The marketing site in `website/` is the brand register and already
carries the visual identity; the app inherits it, it does not reinvent it.

## What it is

Always-on, local-first audio recording + transcription for the Mac. huske
(Norwegian: "to remember") listens to the microphone and system audio, writes
Markdown transcripts on-device, and makes them searchable. Nothing leaves the
machine.

## Users & context

A single technical owner-operator (developers, researchers, memory-keepers)
running huske all day on their own Mac — often in the background via a login
agent. The app is glanced at (is it recording? what did it hear?) far more
than it is operated. Ambient light varies; the reference environment is a
developer's dark desktop next to a terminal.

## Personality (3 words)

Terminal-native. Scandinavian-calm. Warm.

The palette semantics are load-bearing: **amber is the lantern** (recording,
focus, the thing to notice), **spruce is quiet trust** (ok-states, local,
archival), **ink and paper** are the surfaces. One soft moment only: the word
*huske* set in italic serif.

## Anti-references

- Default macOS system-blue chrome — the tell that no design happened.
- SaaS dashboard grammar: gradient heroes, glassmorphism, metric-card grids.
- Consumer-recorder skeuomorphism (VU needles, brushed metal, waveforms as
  decoration).
- Anything loud. huske sits in the corner of a day; it must never shout.

## Strategic principles

1. **State is the interface.** Recording / paused / draining / idle must be
   readable in half a second from across the room — color + one word.
2. **Monospace is voice.** Timestamps, session ids, dB, filenames, and
   eyebrows are set in mono; prose and labels in sans. That contrast IS the
   brand in-app.
3. **Earned familiarity.** Standard macOS affordances (sidebar nav, toggles,
   pickers) styled with the brand — never invented controls.
4. **The engine speaks.** Errors and hints come from the engine's own words,
   cleaned up — the app never paraphrases diagnostics it didn't produce.

## Accessibility

Dark and light both first-class (dark = terminal surface, light = paper).
Body text ≥ 4.5:1 on its surface. Respect Reduce Motion (recording pulse
becomes static). All meters carry text equivalents (dB readouts).
