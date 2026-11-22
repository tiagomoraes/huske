// huske's visual language on iOS — mirrors DESIGN.md / website/colors_and_type.css
// (and macos/Sources/Huske/Theme.swift). Compiled into the app and the Live
// Activity extension, so it only uses extension-safe API.
//
// Amber is the lantern (primary action, focus, live progress), spruce is quiet
// trust (done/ok), rec-red is the active recording. Ink and paper are surfaces.

import SwiftUI
import UIKit

enum Brand {
    // MARK: signal colors

    static let amber = dynamic(light: 0xD88A3A, dark: 0xD88A3A)
    static let amberPressed = dynamic(light: 0xB66E22, dark: 0xE49B54)
    static let recordRed = dynamic(light: 0xC84A3A, dark: 0xD25A49)
    static let ok = dynamic(light: 0x5E8B6E, dark: 0x74A886)
    static let warn = dynamic(light: 0xA97B2C, dark: 0xD9AC5E)
    static let err = dynamic(light: 0xB8543D, dark: 0xD06A52)
    static let info = dynamic(light: 0x5A7A95, dark: 0x7A9AB5)

    // MARK: surfaces

    static let bg = dynamic(light: 0xFBF8F1, dark: 0x0E1116)
    static let bgElevated = dynamic(light: 0xFFFFFF, dark: 0x161A20)
    static let bgSubtle = dynamic(light: 0xF4EFE3, dark: 0x161A20)
    static let bgSunken = dynamic(light: 0xE8E1CF, dark: 0x0A0D11)
    static let border = dynamic(light: 0xD6CDB6, dark: 0x2A2F38)
    static let divider = dynamic(light: 0xE8E1CF, dark: 0x20252D)

    // MARK: text

    static let fg = dynamic(light: 0x0E1116, dark: 0xF4EFE3)
    static let fgMuted = dynamic(light: 0x6B6C70, dark: 0x9CA0A8)
    static let fgFaint = dynamic(light: 0xB8B5AC, dark: 0x5C6068)
    /// Text on an amber fill is always ink.
    static let fgOnAmber = Color(uiColor: UIColor(rgb: 0x0E1116))
    static let fgOnRed = Color(uiColor: UIColor(rgb: 0xFBF8F1))

    /// Fixed (non-adaptive) tokens for the Live Activity, which always sits on
    /// a dark system material (Dynamic Island is black; the Lock Screen banner
    /// gets an explicit ink background).
    enum Ink {
        static let bg = Color(uiColor: UIColor(rgb: 0x0E1116))
        static let bgElevated = Color(uiColor: UIColor(rgb: 0x161A20))
        static let fg = Color(uiColor: UIColor(rgb: 0xF4EFE3))
        static let fgMuted = Color(uiColor: UIColor(rgb: 0x9CA0A8))
        static let fgFaint = Color(uiColor: UIColor(rgb: 0x5C6068))
        static let border = Color(uiColor: UIColor(rgb: 0x2A2F38))
        static let amber = Color(uiColor: UIColor(rgb: 0xD88A3A))
        static let recordRed = Color(uiColor: UIColor(rgb: 0xD25A49))
        static let warn = Color(uiColor: UIColor(rgb: 0xD9AC5E))
    }

    // MARK: geometry (terminal-precise radii)

    static let radiusSM: CGFloat = 4
    static let radiusMD: CGFloat = 6
    static let radiusLG: CGFloat = 10
    static let radiusXL: CGFloat = 14

    // MARK: motion

    static let easeFast = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.12)
    static let ease = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.2)
    static let easeSlow = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.32)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - type

/// IBM Plex, bundled from macos/Sources/Huske/Resources/Fonts and declared in
/// each target's `UIAppFonts`. Every helper scales with Dynamic Type via
/// `relativeTo:`. If a face is missing iOS falls back to the system font.
extension Font {
    /// IBM Plex Sans — labels and prose.
    static func plexSans(_ size: CGFloat, _ weight: Font.Weight = .regular,
                         relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(sansFace(weight), size: size, relativeTo: style)
    }

    /// IBM Plex Mono — time only: the running timer, timecodes, durations.
    static func plexMono(_ size: CGFloat, _ weight: Font.Weight = .regular,
                         relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(monoFace(weight), size: size, relativeTo: style)
    }

    /// IBM Plex Serif — what people said: transcripts and their excerpts.
    static func plexSerif(_ size: CGFloat, _ weight: Font.Weight = .regular,
                          relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight == .medium || weight == .semibold ? "IBMPlexSerif-Medium" : "IBMPlexSerif-Regular",
                size: size, relativeTo: style)
    }

    /// IBM Plex Serif Italic — the word *huske* only.
    static func plexSerifItalic(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("IBMPlexSerif-Italic", size: size, relativeTo: style)
    }

    private static func sansFace(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin: return "IBMPlexSans-Light"
        case .light: return "IBMPlexSans-Light"
        case .medium: return "IBMPlexSans-Medium"
        case .semibold: return "IBMPlexSans-SemiBold"
        case .bold, .heavy, .black: return "IBMPlexSans-Bold"
        default: return "IBMPlexSans-Regular"
        }
    }

    private static func monoFace(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium: return "IBMPlexMono-Medium"
        case .semibold, .bold, .heavy, .black: return "IBMPlexMono-SemiBold"
        default: return "IBMPlexMono-Regular"
        }
    }
}
