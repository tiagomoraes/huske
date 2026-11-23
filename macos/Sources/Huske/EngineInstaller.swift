// One-click install/upgrade of the huske engine for onboarding: detects a
// package manager the user already has (uv preferred — fastest, no sudo;
// Homebrew otherwise), streams its output into the UI, and never blocks.
// The heavy lifting stays in the package manager; the app only supervises.

import Foundation
import HuskeKit
import Observation

@MainActor
@Observable
final class EngineInstaller {
    enum Kind {
        case install
        case upgrade
    }

    enum Manager: String, CaseIterable, Identifiable {
        case uv
        case brew

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .uv: return "uv"
            case .brew: return "Homebrew"
            }
        }

        var binaryCandidates: [String] {
            switch self {
            case .uv: return ["~/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            case .brew: return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            }
        }

        func arguments(for kind: Kind) -> [String] {
            switch (self, kind) {
            case (.uv, .install): return ["tool", "install", "huske"]
            case (.uv, .upgrade): return ["tool", "upgrade", "huske"]
            case (.brew, .install): return ["install", "tiagomoraes/huske/huske"]
            case (.brew, .upgrade): return ["upgrade", "huske"]
            }
        }

        func commandLine(for kind: Kind) -> String {
            switch (self, kind) {
            case (.uv, .install): return "uv tool install huske"
            case (.uv, .upgrade): return "uv tool upgrade huske"
            case (.brew, .install): return "brew install tiagomoraes/huske/huske"
            case (.brew, .upgrade): return "brew upgrade huske"
            }
        }

        func locate(fileManager: FileManager = .default) -> URL? {
            for candidate in binaryCandidates {
                let path = (candidate as NSString).expandingTildeInPath
                if fileManager.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            return nil
        }
    }

    private(set) var running = false
    private(set) var failed = false
    private(set) var log: [String] = []

    /// Managers present on this Mac, in preference order.
    static func available() -> [Manager] {
        Manager.allCases.filter { $0.locate() != nil }
    }

    /// Where an engine came from. This decides whether an in-app upgrade can
    /// even reach it — and offering one that cannot is worse than offering
    /// nothing: `uv tool upgrade huske` exits 0 having upgraded some *other*
    /// engine, and the screen the user is staring at does not change.
    enum Provenance: Equatable {
        /// A package manager owns it; upgrading in place is meaningful.
        case managed(Manager)
        /// A `pip install -e .` checkout. Its version comes from the source
        /// tree, so no package manager can move it.
        case sourceCheckout
        case unknown
    }

    /// Resolves the uv-tool and Homebrew layouts behind `~/.local/bin`
    /// symlinks, then falls back to the venv marker one level above a console
    /// script.
    static func provenance(of binary: URL, fileManager: FileManager = .default) -> Provenance {
        let resolved = binary.resolvingSymlinksInPath()
        let path = resolved.path
        if path.contains("/uv/tools/") { return .managed(.uv) }
        if path.contains("/Cellar/") { return .managed(.brew) }
        let venvMarker = resolved
            .deletingLastPathComponent()      // …/bin
            .deletingLastPathComponent()      // …/<venv>
            .appendingPathComponent("pyvenv.cfg")
        if path.contains("/.venv/") || fileManager.fileExists(atPath: venvMarker.path) {
            return .sourceCheckout
        }
        return .unknown
    }

    /// Which manager owns an installed binary. nil means no manager can
    /// upgrade this one — say something honest instead of guessing.
    static func owner(of binary: URL) -> Manager? {
        if case .managed(let manager) = provenance(of: binary) { return manager }
        return nil
    }

    /// Run the manager and stream output. Returns true on exit 0.
    @discardableResult
    func run(_ kind: Kind, using manager: Manager) async -> Bool {
        guard !running, let bin = manager.locate() else { return false }
        running = true
        failed = false
        log = ["$ " + ([bin.lastPathComponent] + manager.arguments(for: kind)).joined(separator: " ")]
        let status: Int32
        do {
            status = try await CLIRunner.stream(
                binary: bin,
                arguments: manager.arguments(for: kind),
                onLine: { [weak self] line in
                    // EngineProcess delivers on the main queue.
                    MainActor.assumeIsolated {
                        self?.log.append(line)
                    }
                }
            )
        } catch {
            log.append("failed to launch \(manager.displayName): \(error.localizedDescription)")
            status = -1
        }
        running = false
        failed = status != 0
        if failed {
            log.append("exited with status \(status)")
        }
        return status == 0
    }
}
