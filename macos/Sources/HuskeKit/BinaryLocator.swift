// Finds the `huske` CLI the app should drive. Order: explicit override
// (user-picked path in app settings) → the newest engine among the well-known
// install locations and the process PATH.
//
// "Newest", not "first found", is load-bearing. A Mac easily accumulates
// several engines — `uv tool install` puts one in ~/.local/bin, Homebrew puts
// one in /opt/homebrew/bin, a checkout adds a venv — and they drift apart at
// different times. Picking by list position meant whichever manager happened
// to be listed first won even when it was a release behind, so the app could
// silently drive an old engine while a current one sat next to it. That is how
// a 0.10.0 uv tool shadowed a freshly installed 0.11.0 brew engine.
//
// Version comparison is a fallback signal, not the contract: the app
// feature-probes whatever it picks (see EngineCapabilities) because a dev build
// cannot be told from a release by its version string. This only decides which
// candidate to probe first.

import Foundation

/// A `huske` executable found on disk, with the version it reports.
public struct EngineCandidate: Equatable, Sendable {
    public let url: URL
    /// `nil` when the binary would not report a parseable version.
    public let version: EngineVersion?
    /// Where it came from, for display: "~/.local/bin", "/opt/homebrew/bin", "PATH".
    public let origin: String

    public init(url: URL, version: EngineVersion?, origin: String) {
        self.url = url
        self.version = version
        self.origin = origin
    }
}

/// A comparable `MAJOR.MINOR.PATCH` with an optional trailing suffix.
///
/// Suffixes (`0.11.0.dev3`, `0.12.0rc1`) sort *below* the plain release so a
/// prerelease never displaces a shipped engine on version alone.
public struct EngineVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let isPrerelease: Bool
    public let raw: String

    public init?(_ text: String) {
        let trimmed = text
            .replacingOccurrences(of: "huske", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Leading numeric dotted run; anything after it is a suffix.
        var digits: [Int] = []
        var idx = trimmed.startIndex
        var current = ""
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch.isNumber {
                current.append(ch)
            } else if ch == "." , !current.isEmpty, digits.count < 2 {
                digits.append(Int(current) ?? 0)
                current = ""
            } else {
                break
            }
            idx = trimmed.index(after: idx)
        }
        guard !current.isEmpty else { return nil }
        digits.append(Int(current) ?? 0)
        guard !digits.isEmpty else { return nil }

        major = digits.count > 0 ? digits[0] : 0
        minor = digits.count > 1 ? digits[1] : 0
        patch = digits.count > 2 ? digits[2] : 0
        isPrerelease = idx < trimmed.endIndex
        raw = trimmed
    }

    public var description: String { raw }

    public static func < (a: EngineVersion, b: EngineVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // Same numbers: a prerelease is older than the release.
        return a.isPrerelease && !b.isPrerelease
    }
}

public enum BinaryLocator {
    public static let wellKnownPaths: [String] = [
        "~/.local/bin/huske",          // uv tool / pipx default
        "/opt/homebrew/bin/huske",     // brew (Apple Silicon)
        "/usr/local/bin/huske",        // brew (Intel) / manual installs
    ]

    /// Asks a binary for its version. Injected so tests never exec anything.
    public typealias VersionProbe = (URL) -> String?

    /// Runs `huske --version`. Cheap (no model load) but still a subprocess, so
    /// callers should resolve once and cache, not call this per frame.
    public static func probeVersion(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every distinct `huske` on this machine, in discovery order.
    ///
    /// Deduplicated by *resolved* path, so a `~/.local/bin/huske` symlink into a
    /// uv tool directory and that directory's own entry count once.
    public static func candidates(
        wellKnown: [String] = wellKnownPaths,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probe: VersionProbe = probeVersion
    ) -> [EngineCandidate] {
        var seen = Set<String>()
        var found: [EngineCandidate] = []

        func consider(_ path: String, origin: String) {
            let expanded = (path as NSString).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: expanded) else { return }
            let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { return }
            let url = URL(fileURLWithPath: expanded)
            found.append(
                EngineCandidate(
                    url: url,
                    version: probe(url).flatMap(EngineVersion.init),
                    origin: origin
                )
            )
        }

        for candidate in wellKnown {
            consider(candidate, origin: (candidate as NSString).deletingLastPathComponent)
        }
        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                consider(String(dir) + "/huske", origin: String(dir))
            }
        }
        return found
    }

    /// The engine the app should drive: the highest version among the
    /// candidates, ties broken by discovery order. A candidate whose version
    /// could not be read loses to any that reported one, but still wins over
    /// nothing at all.
    public static func best(among candidates: [EngineCandidate]) -> EngineCandidate? {
        guard !candidates.isEmpty else { return nil }
        let versioned = candidates.filter { $0.version != nil }
        guard !versioned.isEmpty else { return candidates.first }
        // max(by:) keeps the *last* maximum; reduce keeps the first, which is
        // what "ties broken by discovery order" means.
        return versioned.dropFirst().reduce(versioned[0]) { best, next in
            (next.version! > best.version!) ? next : best
        }
    }

    /// Candidates that are installed but *not* the one in use, newest first.
    ///
    /// Surfaced in the UI: "which huske" decides what actually records, so a
    /// second engine sitting one directory away should be visible rather than
    /// silently losing a precedence contest.
    public static func shadowed(
        among candidates: [EngineCandidate], chosen: URL?
    ) -> [EngineCandidate] {
        let current = chosen?.resolvingSymlinksInPath()
        let others = candidates.filter { $0.url.resolvingSymlinksInPath() != current }
        // Compare parsed versions, never their strings — "0.9.0" sorts above
        // "0.11.0" lexically, which is the class of bug this file exists to fix.
        return others.sorted { a, b in
            guard let bv = b.version else { return a.version != nil }
            guard let av = a.version else { return false }
            return av > bv
        }
    }

    /// Resolve the engine to use. An explicit override always wins — and an
    /// explicit-but-broken override returns nil rather than silently falling
    /// back to some other engine the user did not choose.
    public static func locate(
        override: String? = nil,
        wellKnown: [String] = wellKnownPaths,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probe: VersionProbe = probeVersion
    ) -> URL? {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            return nil
        }
        let found = candidates(
            wellKnown: wellKnown,
            fileManager: fileManager,
            environment: environment,
            probe: probe
        )
        return best(among: found)?.url
    }
}
