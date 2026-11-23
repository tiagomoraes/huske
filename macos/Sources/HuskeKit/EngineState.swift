// The one place that decides what the app says about the engine it found —
// and therefore which setup screen, which button, and which copy the user
// gets.
//
// It exists because three genuinely different situations used to collapse into
// two screens: "no engine installed" (onboarding) and "engine too old"
// (upgrade). A pinned engine that cannot execute is neither. It landed on the
// upgrade screen, where the offered `uv tool upgrade huske` exits 0 having
// upgraded a *different* engine, leaving the same screen on the glass — an
// update prompt with no reachable end. Naming the states separately is what
// lets each one offer something that can actually finish.

import Foundation

public enum EngineState: Equatable, Sendable {
    /// Healthy, or still being probed — either way, no setup screen.
    case ready
    /// No `huske` anywhere on this Mac: first-run onboarding.
    case missing
    /// An engine is selected but cannot run. An upgrade cannot fix this;
    /// switching engines or repairing the install can.
    case unusable(path: String, reason: String)
    /// It runs, and predates the control protocol the app drives.
    case outdated(path: String, version: String?)

    /// True while the app can drive sessions.
    public var canRecord: Bool { self == .ready }
}

public enum EngineStateResolver {
    /// - Parameters:
    ///   - binary: what `BinaryLocator` resolved, `nil` when nothing resolved.
    ///   - override: the user's pinned path, if any. Load-bearing when
    ///     `binary` is nil: a pinned path that stopped resolving is a broken
    ///     choice to repair, not a fresh Mac to onboard.
    ///   - capabilities: `nil` while probing — deliberately optimistic, so a
    ///     setup screen never flashes between launch and the first probe.
    public static func resolve(
        binary: URL?,
        override: String?,
        capabilities: EngineCapabilities?
    ) -> EngineState {
        guard let binary else {
            if let override, !override.isEmpty {
                return .unusable(
                    path: override,
                    reason: "There is no executable at that path any more.")
            }
            return .missing
        }
        guard let capabilities else { return .ready }
        if let failure = capabilities.failure {
            return .unusable(path: binary.path, reason: failure)
        }
        if !capabilities.controlSocket {
            return .outdated(path: binary.path, version: capabilities.version)
        }
        return .ready
    }
}
