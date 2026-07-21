// Finds the `huske` CLI the app should drive. Order: explicit override
// (user-picked path in app settings) → well-known install locations →
// the current process PATH.

import Foundation

public enum BinaryLocator {
    public static let wellKnownPaths: [String] = [
        "~/.local/bin/huske",          // uv tool / pipx default
        "/opt/homebrew/bin/huske",     // brew (Apple Silicon)
        "/usr/local/bin/huske",        // brew (Intel) / manual installs
    ]

    public static func locate(
        override: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            return nil // an explicit-but-broken override should not silently fall back
        }
        for candidate in wellKnownPaths {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = String(dir) + "/huske"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }
}
