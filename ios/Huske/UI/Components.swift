// Small brand components: section labels, cards, the state ring + status
// line, buttons. One vocabulary, used everywhere — DESIGN.md "Quiet
// instrument": state is a glyph and plain words, never a pill.

import SwiftUI

/// A section label: sentence case, sans, muted. (Was a mono uppercase
/// eyebrow; the name stays so call sites read the same.)
struct Eyebrow: View {
    let text: String
    var color: Color = Brand.fgMuted

    init(_ text: String, color: Color = Brand.fgMuted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.plexSans(13, .medium, relativeTo: .footnote))
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous)
                    .fill(Brand.bgElevated))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous)
                    .strokeBorder(Brand.border, lineWidth: 1))
    }
}

/// A pulsing dot; static under Reduce Motion. Only for *live* things
/// (recording, a Mac that is reachable right now).
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var pulsing = false

    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing && !reduceMotion && dim ? 0.3 : 1)
            .onAppear { startPulse() }
            .onChange(of: pulsing) { startPulse() }
    }

    private func startPulse() {
        guard pulsing, !reduceMotion else {
            dim = false
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

/// The state ring: a 12 pt circle that fills as a recording moves through
/// the pipeline. Hairline = waiting, ink = held by the Mac, amber arc = work
/// happening now (proportional when known), red dot = recording.
struct StateRing: View {
    enum Kind: Equatable {
        case waiting
        case held
        case progress(Double?)
        case live
        case done
        case failed
    }

    let kind: Kind
    var size: CGFloat = 12

    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch kind {
            case .waiting:
                Circle().strokeBorder(Brand.fgFaint, lineWidth: 1.25)
            case .held:
                Circle().strokeBorder(Brand.fgMuted, lineWidth: 1.25)
            case .progress(let fraction):
                Circle().strokeBorder(Brand.fgFaint.opacity(0.7), lineWidth: 1.25)
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.06, min($0, 1)) } ?? 0.28)
                    .stroke(Brand.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .rotationEffect(.degrees(fraction == nil && spin ? 360 : 0))
                    .padding(1)
            case .live:
                StatusDot(color: Brand.recordRed, size: size * 0.66, pulsing: true)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.8, weight: .semibold))
                    .foregroundStyle(Brand.fgMuted)
            case .failed:
                Circle().strokeBorder(Brand.err, lineWidth: 1.25)
                Circle().fill(Brand.err).frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .onAppear { startSpin() }
        .onChange(of: kind) { startSpin() }
        .accessibilityHidden(true)
    }

    private func startSpin() {
        guard case .progress(nil) = kind, !reduceMotion else {
            spin = false
            return
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true }
    }
}

/// Where a recording is, in plain words beside its state ring. No container.
/// A transcribed recording shows nothing (its transcript speaks for it)
/// unless `showsDone` is set.
struct SyncBadgeView: View {
    let badge: SyncBadge
    var compact = true
    var showsDone = false

    var body: some View {
        if badge == .transcribed && !showsDone {
            EmptyView()
        } else {
            HStack(spacing: 7) {
                StateRing(kind: badge.ringKind, size: compact ? 11 : 12)
                Text(badge.label)
                    .font(.plexSans(compact ? 13 : 14, relativeTo: .footnote))
                    .foregroundStyle(badge.isProblem ? Brand.err : Brand.fgMuted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.accessibilityLabel)
        }
    }
}

extension SyncBadge {
    var ringKind: StateRing.Kind {
        switch self {
        case .recording: return .live
        case .onPhone, .waitingForMac: return .waiting
        case .uploading(let fraction): return .progress(fraction)
        case .onMac, .queued: return .held
        case let .transcribing(done, total, fraction):
            if let done, let total, total > 0 { return .progress(Double(done) / Double(total)) }
            return .progress(fraction.flatMap { $0 > 0 ? $0 : nil })
        case .transcribed: return .done
        case .failed, .damaged: return .failed
        }
    }

    var isProblem: Bool {
        switch self {
        case .failed, .damaged: return true
        default: return false
        }
    }
}

extension SyncBadge.Tone {
    var color: Color {
        switch self {
        case .recording: return Brand.recordRed
        case .neutral: return Brand.fgMuted
        case .active: return Brand.amber
        case .info: return Brand.fgMuted
        case .ok: return Brand.fgMuted
        case .error: return Brand.err
        }
    }
}

// MARK: - buttons

/// Primary: amber fill, ink text. The screen's one accent.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, fullWidth: fullWidth)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.plexSans(17, .semibold, relativeTo: .body))
                .foregroundStyle(Brand.fgOnAmber)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous)
                        .fill(configuration.isPressed ? Brand.amberPressed : Brand.amber))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Brand.easeFast, value: configuration.isPressed)
        }
    }
}

/// Secondary: hairline border on an elevated fill.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    var tint: Color = Brand.fg

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, fullWidth: fullWidth, tint: tint)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.plexSans(17, .medium, relativeTo: .body))
                .foregroundStyle(tint)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous)
                        .fill(configuration.isPressed ? Brand.divider : Brand.bgElevated))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous)
                        .strokeBorder(Brand.border, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Brand.easeFast, value: configuration.isPressed)
        }
    }
}

/// A round icon button (player transport, recorder controls).
struct CircleIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 56
    var fill: Color = Brand.bgElevated
    var foreground: Color = Brand.fg
    var bordered = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(bordered ? Brand.border : .clear, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Brand.easeFast, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

// MARK: - formatting

enum Format {
    /// 75 → "1:15", 3725 → "1:02:05".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Spoken form for VoiceOver: "1 minute, 15 seconds".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "Today", "Yesterday", "Mon 17 Nov", "17 Nov 2025".
    static func dayHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        if sameYear {
            return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return day.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 45 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}
