// Feature-detects the installed huske CLI. The app needs `--control-socket`
// (0.11+) to supervise a session, and the `config`/`devices` subcommands for
// its Configuration pane. Version strings can't distinguish a dev build from
// a release, so this probes the actual help output instead.

import Foundation

public struct EngineCapabilities: Equatable, Sendable {
    public let version: String?
    /// `huske run --control-socket` exists — the app can own sessions.
    public let controlSocket: Bool
    /// `huske config` subcommand exists.
    public let configCLI: Bool
    /// `huske devices` subcommand exists.
    public let devicesCLI: Bool

    public init(version: String?, controlSocket: Bool, configCLI: Bool, devicesCLI: Bool) {
        self.version = version
        self.controlSocket = controlSocket
        self.configCLI = configCLI
        self.devicesCLI = devicesCLI
    }

    public var isCurrent: Bool { controlSocket && configCLI && devicesCLI }

    /// Pure derivation from CLI output — unit-testable.
    public static func parse(
        versionOutput: String, runHelp: String, mainHelp: String
    ) -> EngineCapabilities {
        let version = versionOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "huske ", with: "")
        return EngineCapabilities(
            version: version.isEmpty ? nil : version,
            controlSocket: runHelp.contains("--control-socket"),
            configCLI: containsCommand(mainHelp, "config"),
            devicesCLI: containsCommand(mainHelp, "devices")
        )
    }

    private static func containsCommand(_ help: String, _ command: String) -> Bool {
        // Typer lists subcommands one per row; match a leading word so free
        // text like "configured microphone" can't false-positive.
        for line in help.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " │╭╰─╮╯"))
            if trimmed.hasPrefix(command + " ") || trimmed == command {
                return true
            }
        }
        return false
    }

    public static func probe(binary: URL) async -> EngineCapabilities {
        async let versionRun = try? CLIRunner.run(
            binary: binary, arguments: ["--version"], timeout: 30)
        async let runHelpRun = try? CLIRunner.run(
            binary: binary, arguments: ["run", "--help"], timeout: 30)
        async let mainHelpRun = try? CLIRunner.run(
            binary: binary, arguments: ["--help"], timeout: 30)
        let (version, runHelp, mainHelp) = await (versionRun, runHelpRun, mainHelpRun)
        return parse(
            versionOutput: version?.stdout ?? "",
            runHelp: runHelp?.stdout ?? "",
            mainHelp: mainHelp?.stdout ?? ""
        )
    }
}

public enum EngineOutput {
    /// Strip Typer/Rich box-drawing furniture from engine error output so it
    /// can be shown as prose.
    public static func sanitize(_ lines: [String]) -> String {
        let boxChars = CharacterSet(charactersIn: "╭╮╰╯│─┌┐└┘├┤━┃")
        var cleaned: [String] = []
        for raw in lines {
            let stripped = raw
                .components(separatedBy: boxChars)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty, stripped != "Error" else { continue }
            cleaned.append(stripped)
        }
        return cleaned.joined(separator: "\n")
    }
}
