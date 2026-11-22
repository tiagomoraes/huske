// The link to the paired Mac as a glyph and plain words (DESIGN.md, "Quiet
// instrument": state is a glyph and a sentence, never a pill). Used on the
// Mac screen and in the home header.

import SwiftUI

/// The glyph alone: filled spruce = the Mac is there, hairline ring = away,
/// amber arc = connecting now, warn ring = waiting on something, err ring =
/// only you can fix it.
struct LinkGlyph: View {
    let state: LinkState
    /// A pass is running (uploading, checking): the dot breathes.
    var isBusy = false

    var body: some View {
        Group {
            switch state {
            case .visible:
                StatusDot(color: Brand.ok, size: 6, pulsing: isBusy)
            case .connected:
                StatusDot(color: Brand.ok, size: 6, pulsing: true)
            case .connecting:
                StateRing(kind: .progress(nil), size: 9)
            case .retrying:
                Circle().strokeBorder(Brand.warn, lineWidth: 1.25).frame(width: 7, height: 7)
            case .localNetworkOff, .rejected:
                StateRing(kind: .failed, size: 9)
            case .searching, .noWiFi, .paused:
                Circle().strokeBorder(Brand.fgFaint, lineWidth: 1.25).frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// Glyph + words. The countdown ("trying again in 12 s") ticks on its own.
struct LinkStatusLine: View {
    let state: LinkState
    var isBusy = false

    var body: some View {
        if case .retrying = state {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                line(now: context.date)
            }
        } else {
            line(now: Date())
        }
    }

    private func line(now: Date) -> some View {
        HStack(spacing: 7) {
            LinkGlyph(state: state, isBusy: isBusy)
            Text(state.label(now: now))
                .font(.plexSans(14, relativeTo: .footnote))
                .foregroundStyle(state.needsSettings || state.needsPairing ? Brand.err : Brand.fgMuted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
