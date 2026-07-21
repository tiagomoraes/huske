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
- **Mono**: IBM Plex Mono — timestamps, ids, dB, filenames, code, eyebrows.
- **Serif italic**: IBM Plex Serif Italic — the word *huske* only.
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
- **StatusPill**: pill, colored dot (pulsing while recording), mono uppercase.
- **Meter**: sunken capsule track, spruce→amber→rec-red gradient by absolute
  level, 2px fg peak-hold tick, mono dB readout.
- **Eyebrow/SectionLabel**: mono 11 medium, +0.12em, uppercase, muted.
- **Buttons**: primary = amber fill + ink text (hover amber-700); secondary =
  1px border + fg (hover border-soft wash); destructive = rec-red fill +
  paper text (Stop only); ghost links in amber.
- **Cards**: bg-elev, radius 10, 1px border, 16px padding.
