// huske's visual language, carried over from the website and TUI:
// warm amber on terminal ink, paper neutrals, spruce for ok-states.
// Every color adapts to light/dark via NSColor dynamic providers.

import AppKit
import SwiftUI

enum Theme {
    // MARK: brand palette

    /// Primary signal — recording focus, links, accents. (#D88A3A)
    static let amber = dynamic(light: 0xD88A3A, dark: 0xE09A4E)
    static let amberPressed = dynamic(light: 0xB66E22, dark: 0xC67E32)
    /// Active recording dot. (#C84A3A)
    static let recordRed = dynamic(light: 0xC84A3A, dark: 0xD65A48)
    static let ok = dynamic(light: 0x5E8B6E, dark: 0x74A886)
    static let warn = dynamic(light: 0xC99A4A, dark: 0xD9AC5E)
    static let err = dynamic(light: 0xB8543D, dark: 0xD06A52)
    static let info = dynamic(light: 0x5A7A95, dark: 0x7A9AB5)

    // MARK: surfaces

    static let bg = dynamic(light: 0xFBF8F1, dark: 0x0E1116)
    static let bgElevated = dynamic(light: 0xFFFFFF, dark: 0x161A20)
    static let bgSunken = dynamic(light: 0xE8E1CF, dark: 0x0A0C10)
    static let cardBorder = dynamic(light: 0xD6CDB6, dark: 0x2A2F38)
    static let divider = dynamic(light: 0xE8E1CF, dark: 0x20252D)

    // MARK: text

    static let fg = dynamic(light: 0x0E1116, dark: 0xF4EFE3)
    static let fgMuted = dynamic(light: 0x75767A, dark: 0x9A9C9F)
    static let fgFaint = dynamic(light: 0xB8B5AC, dark: 0x5E6167)

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

// MARK: - shared view chrome

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardBorder.opacity(0.6), lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.fgMuted)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? (pulse ? 1.0 : 0.35) : 1.0)
                .animation(
                    pulsing
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear { pulse = true }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.fg)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

extension View {
    /// Monospaced digits + tabular feel for timers and dB readouts.
    func meterFigure(size: CGFloat = 12, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
    }
}
