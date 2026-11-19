// IBM Plex — the huske brand type (bundled from website/fonts, OFL).
// Sans carries the interface, Serif carries what people said (transcripts),
// Mono carries time and file names only, and the italic Serif is reserved
// for the word "huske" (DESIGN.md, "Quiet instrument"). Registration is
// best-effort: if a font fails to load the helpers fall back to the system
// stacks the website also falls back to.

import AppKit
import CoreText
import SwiftUI

enum BrandFonts {
    private(set) nonisolated(unsafe) static var registered = false

    static let files = [
        "IBMPlexSans-Variable",
        "IBMPlexMono-Regular",
        "IBMPlexMono-Medium",
        "IBMPlexMono-SemiBold",
        "IBMPlexSerif-Italic",
        "IBMPlexSerif-Regular",
        "IBMPlexSerif-Medium",
    ]

    /// Idempotent; call once at app start (before any view renders).
    static func registerAll() {
        guard !registered else { return }
        var loadedAny = false
        for name in files {
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                loadedAny = true
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
            {
                loadedAny = true
            }
        }
        registered = loadedAny
    }
}

extension Font {
    /// IBM Plex Sans (falls back to SF).
    static func brandSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFonts.registered else {
            return .system(size: size, weight: weight)
        }
        return .custom("IBM Plex Sans", size: size).weight(weight)
    }

    /// IBM Plex Mono (falls back to SF Mono). Static weights 400/500/600.
    static func brandMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFonts.registered else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        switch weight {
        case .medium:
            return .custom("IBM Plex Mono Medium", size: size)
        case .semibold, .bold, .heavy, .black:
            return .custom("IBM Plex Mono SemiBold", size: size)
        default:
            return .custom("IBM Plex Mono", size: size)
        }
    }

    /// IBM Plex Serif — what people said (transcripts, excerpts).
    static func brandSerif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFonts.registered else {
            return .system(size: size, weight: weight, design: .serif)
        }
        return .custom(weight == .medium || weight == .semibold ? "IBM Plex Serif Medium" : "IBM Plex Serif", size: size)
    }

    /// IBM Plex Serif Italic — reserved for the word "huske".
    static func brandSerifItalic(_ size: CGFloat) -> Font {
        guard BrandFonts.registered else {
            return .system(size: size, design: .serif).italic()
        }
        return .custom("IBM Plex Serif", size: size).italic()
    }
}
