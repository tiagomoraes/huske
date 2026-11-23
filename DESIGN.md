# huske — design system

Source of truth: `website/colors_and_type.css`. The macOS app
(`macos/Sources/Huske/Theme.swift`) mirrors these tokens; change them together.

## Theme

Dual-surface. **Light = warm paper** (site default), **dark = terminal ink**
(the app's home). Every color is a light/dark pair.

## Color

| Role | Light | Dark |
|---|---|---|
| bg | `#FBF8F1` paper-50 | `#0E1116` ink-900 |
| bg-elev (cards) | `#FFFFFF` | `#161A20` ink-800 |
| bg-sunken | `#E8E1CF` | `#0A0D11` |
| fg | `#0E1116` | `#F4EFE3` paper-100 |
| fg-muted | `#75767A` | `#9CA0A8` |
| fg-faint | `#B8B5AC` | `#5C6068` |
| border | `#D6CDB6` | `#2A2F38` ink-600 |
| border-soft / divider | `#E8E1CF` | `#20252D` ink-700 |
| accent (amber) | `#D88A3A`, hover `#B66E22` | same amber; hover lighter |
| accent-fg (on amber) | `#0E1116` | `#0E1116` |
| ok (spruce) | `#5E8B6E` | `#5E8B6E`+ |
| warn | `#C99A4A` | + |
| err | `#B8543D` | + |
| info | `#5A7A95` | + |
| rec-on | `#C84A3A` | + |

Amber is *signal only*: recording focus, selection, links, primary action.
Never decoration. Spruce = ok/quiet-trust. Restrained strategy; accent ≤10%
of any screen.

## Typography

- **Sans**: IBM Plex Sans (variable) — headings, labels, prose. Fallback SF.
- **Mono**: IBM Plex Mono — time (timestamps, durations), ids, dB, filenames,
  code. Never labels or headings (see "Quiet instrument").
- **Serif**: IBM Plex Serif — what people said (transcripts, excerpts); its
  italic is reserved for the word *huske*.
- Scale (app): h1 20/semibold −0.015em · h2 15/semibold · body 13 · small
  12 · caption/mono-sm 11 · eyebrow 11 mono medium +0.12em uppercase muted.
- Product register: fixed sizes, ~1.2 ratio, no fluid type.

## Geometry & elevation

- Radii: 2 / **4 (default, terminal-precise)** / 6 / 10 / 14 / pill.
  Controls 4–6, cards 10, app icon 14. Pills only for status pills/badges.
- Borders 1px (`border` on cards, `border-soft` for dividers).
- Shadows: low-contrast paper feel; on dark, deeper blacks. Cards may go
  shadowless with a border.

## Motion

- Durations 120 / 200 / 320 ms; ease `cubic-bezier(.2,.7,.2,1)`.
- Motion conveys state only: recording pulse, meter physics, drain progress.
- Reduce Motion: pulse becomes solid, meters still track (data, not motion).

## App-specific components (`macos/`)

- **Sidebar**: hidden title bar; ink-800/paper-100 rail, logo mark +
  *huske* wordmark (serif italic), nav rows with amber selection wash
  (amber 14% bg, amber icon), live session badge at the bottom.
- **StatusPill** (name kept for call sites): *not* a pill — a state glyph
  + sentence-case sans text, no container. See "Quiet instrument" below.
- **Meter**: sunken capsule track, spruce→amber→rec-red gradient by absolute
  level, 2px fg peak-hold tick, mono dB readout.
- **SectionLabel**: sans 12 medium, sentence case, muted, normal tracking.
- **Buttons**: primary = amber fill + ink text (hover amber-700); secondary =
  1px border + fg (hover border-soft wash); destructive = rec-red fill +
  paper text (Stop only); ghost links in amber.
- **Cards**: bg-elev, radius 10, 1px border, 16px padding.

## Quiet instrument (the app language, 2026-11)

The apps had drifted into the generic "AI dashboard" look: tinted capsules
with a dot and mono UPPERCASE text, letter-spaced mono eyebrows over every
group, everything boxed in bordered cards, mono used for names. huske is an
instrument for remembering — the reference points are a Braun / Teenage
Engineering recorder and Things: almost all neutral, and every mark means
something.

1. **Content is the interface.** What was said is the hero. Chrome recedes:
   lists sit on the paper with hairline dividers; a card frames only the one
   object a screen is about (the QR code, the player).
2. **Colour only when it means something.** ~95 % paper and ink. Rec-red
   only for recording (the REC control, the live state). Amber only for the screen's one
   primary action and for work happening right now. No green "done" chips —
   done is the normal state and needs no mark.
3. **State is a glyph and plain words, never a pill.** The *state ring*:
   a 12 pt circle that fills as a recording moves through the pipeline —
   hairline ring (waiting) → amber arc (sending / transcribing, proportional)
   → nothing once transcribed, because the transcript itself appears. Failure
   is err-coloured words with the way out ("Couldn't transcribe — Retry").
   Text beside it: sans 13, sentence case ("Sending · 42 %", "Transcribing ·
   2 of 3"). No capsules, no uppercase, no tracking.
4. **Type carries the hierarchy.** Plex Sans for interface. **Plex Serif for
   what people said** (transcripts, excerpts) — a transcript reads like a
   document, with its timecodes in the margin. Plex Mono *only for time*
   (the running timer, timecodes, durations), never for names, labels or
   headings. Section labels are sentence case.
5. **The recorder is hardware.** One round REC control: a hairline ring with a
   red disc that becomes a rounded square while recording. The elapsed time is
   the largest thing on screen, in light tabular numerals. The level is a
   tape-like strip of hairlines, newest at the playhead.
6. **Words.** Say what is happening in the user's terms ("On your Mac",
   "Waiting for MacBook Pro"), never the protocol ("TLS-PSK", "Bonjour").

