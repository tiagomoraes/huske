// huske's visual language — a 1:1 mirror of website/colors_and_type.css
// (see DESIGN.md at the repo root; change them together).
// Warm paper × terminal ink with a single saffron-amber signal. Amber is the
// lantern (recording, focus, selection); spruce is quiet trust (ok-states);
// mono type is the voice for timestamps, ids, and dB.

import AppKit
import SwiftUI

enum Theme {
    // MARK: brand palette

    /// --brand-amber: the one signal color. Never decoration.
    static let amber = dynamic(light: 0xD88A3A, dark: 0xD88A3A)
    /// --brand-amber-700 (hover/pressed on light) / a lifted amber on dark.
    static let amberPressed = dynamic(light: 0xB66E22, dark: 0xE49B54)
    /// --rec-on: the active recording dot.
    static let recordRed = dynamic(light: 0xC84A3A, dark: 0xC84A3A)
    /// --ok: spruce-family calm green.
    static let ok = dynamic(light: 0x5E8B6E, dark: 0x74A886)
    static let warn = dynamic(light: 0xC99A4A, dark: 0xD9AC5E)
    static let err = dynamic(light: 0xB8543D, dark: 0xD06A52)
    static let info = dynamic(light: 0x5A7A95, dark: 0x7A9AB5)

    // MARK: surfaces (paper-50…ink-900 pairs from the token sheet)

    static let bg = dynamic(light: 0xFBF8F1, dark: 0x0E1116)
    static let bgElevated = dynamic(light: 0xFFFFFF, dark: 0x161A20)
    static let bgSubtle = dynamic(light: 0xF4EFE3, dark: 0x161A20)
    static let bgSunken = dynamic(light: 0xE8E1CF, dark: 0x0A0D11)
    /// The sidebar rail — one neutral step off the content surface.
    static let bgSidebar = dynamic(light: 0xF4EFE3, dark: 0x11151B)
    static let cardBorder = dynamic(light: 0xD6CDB6, dark: 0x2A2F38)
    static let divider = dynamic(light: 0xE8E1CF, dark: 0x20252D)

    // MARK: text

    static let fg = dynamic(light: 0x0E1116, dark: 0xF4EFE3)
    static let fgMuted = dynamic(light: 0x75767A, dark: 0x9CA0A8)
    static let fgFaint = dynamic(light: 0xB8B5AC, dark: 0x5C6068)
    /// --accent-fg: text on an amber fill is always ink.
    static let fgOnAmber = Color(nsColor: NSColor(rgb: 0x0E1116))
    static let fgOnRed = dynamic(light: 0xFBF8F1, dark: 0xF4EFE3)

    // MARK: geometry (--radius-*: terminal-precise)

    static let radiusXS: CGFloat = 2
    static let radiusSM: CGFloat = 4
    static let radiusMD: CGFloat = 6
    static let radiusLG: CGFloat = 10

    // MARK: motion (--dur-*, --ease-standard)

    static let easeFast = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.12)
    static let ease = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.2)

    // MARK: helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return NSColor(rgb: isDark ? dark : light)
                }))
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - type shorthands

extension Text {
    /// UI label / prose (IBM Plex Sans).
    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Text {
        font(.brandSans(size, weight))
    }

    /// Terminal voice (IBM Plex Mono) — timestamps, ids, dB, filenames.
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Text {
        font(.brandMono(size, weight))
    }
}

// MARK: - shared chrome

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                    .fill(Theme.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
    }
}

/// The website's `.eyebrow`: mono, uppercase, +0.12em, muted.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.brandMono(11, .medium))
            .kerning(1.3)
            .foregroundStyle(Theme.fgMuted)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(pulsing && !reduceMotion ? (pulse ? 1.0 : 0.35) : 1.0)
                .animation(
                    pulsing && !reduceMotion
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear { pulse = true }
            Text(text.uppercased())
                .font(.brandMono(11, .semibold))
                .kerning(1.1)
                .foregroundStyle(Theme.fg)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(0.38), lineWidth: 1))
    }
}

/// In-window pane header (the app hides the system title bar).
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.brandSans(20, .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(Theme.fg)
                if let subtitle {
                    Text(subtitle)
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - buttons (one vocabulary, used everywhere)

/// Primary action: amber fill, ink text. `huske`'s single accent.
struct PrimaryButtonStyle: ButtonStyle {
    var size: ControlSizeVariant = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brandSans(size.fontSize, .semibold))
            .foregroundStyle(Theme.fgOnAmber)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(configuration.isPressed ? Theme.amberPressed : Theme.amber)
            )
            .pointingCursor()
            .animation(Theme.easeFast, value: configuration.isPressed)
    }
}

/// Secondary action: hairline border, quiet.
struct SecondaryButtonStyle: ButtonStyle {
    var size: ControlSizeVariant = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brandSans(size.fontSize, .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(configuration.isPressed ? Theme.divider : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
            .pointingCursor()
            .animation(Theme.easeFast, value: configuration.isPressed)
    }
}

/// Destructive fill — reserved for Stop.
struct StopButtonStyle: ButtonStyle {
    var size: ControlSizeVariant = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brandSans(size.fontSize, .semibold))
            .foregroundStyle(Theme.fgOnRed)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(Theme.recordRed.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .pointingCursor()
            .animation(Theme.easeFast, value: configuration.isPressed)
    }
}

enum ControlSizeVariant {
    case regular, large, small

    var fontSize: CGFloat {
        switch self {
        case .small: return 12
        case .regular: return 13
        case .large: return 15
        }
    }

    var hPad: CGFloat {
        switch self {
        case .small: return 10
        case .regular: return 14
        case .large: return 24
        }
    }

    var vPad: CGFloat {
        switch self {
        case .small: return 4
        case .regular: return 6
        case .large: return 11
        }
    }
}

extension View {
    /// Monospaced figures for timers and dB readouts.
    func meterFigure(size: CGFloat = 12, weight: Font.Weight = .medium) -> some View {
        font(.brandMono(size, weight))
    }

    /// Pointing-hand cursor over clickable custom controls.
    func pointingCursor() -> some View {
        modifier(PointingCursorModifier())
    }
}

/// Push/pop the pointing hand with the hover state; pop on disappear so a
/// vanishing control can't leave the cursor stuck.
struct PointingCursorModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !hovering {
                    NSCursor.pointingHand.push()
                } else if !inside, hovering {
                    NSCursor.pop()
                }
                hovering = inside
            }
            .onDisappear {
                if hovering {
                    NSCursor.pop()
                    hovering = false
                }
            }
    }
}

// MARK: - offscreen render support

/// True while `--render-screens` is exporting PNGs. ImageRenderer skips
/// ScrollView content, so scrolling containers go static in that mode.
private struct ScreenRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var screenRendering: Bool {
        get { self[ScreenRenderingKey.self] }
        set { self[ScreenRenderingKey.self] = newValue }
    }
}

/// A pane-level scroll container that degrades to a static stack when the
/// offscreen renderer is driving.
struct PaneScroll<Content: View>: View {
    @Environment(\.screenRendering) private var rendering
    @ViewBuilder var content: Content

    var body: some View {
        if rendering {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                content
            }
        }
    }
}
