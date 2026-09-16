// Feature-detects the installed huske CLI. The app needs `--control-socket`
// (0.11+) to supervise a session, and the `config`/`devices` subcommands for
// its Configuration pane. Version strings can't distinguish a dev build from
// a release, so this probes the actual help output instead.
//
// It answers a second question too, which the app used to get wrong: *can this
// binary run at all?* A `huske` on disk is not a working `huske` — a checkout's
// console script outlives the virtualenv it points at, and a half-removed tool
// install leaves its shim behind. Both used to land on the "your engine needs
// an update" screen, whose upgrade button cannot fix either. "Ran and is old"
// and "never ran" need different offers, so probing has to tell them apart.

import Foundation

public struct EngineCapabilities: Equatable, Sendable {
    public let version: String?
    /// `huske run --control-socket` exists — the app can own sessions.
    public let controlSocket: Bool
    /// `huske config` subcommand exists.
    public let configCLI: Bool
    /// `huske devices` subcommand exists.
    public let devicesCLI: Bool
    /// Why this binary cannot be used *at all*, in prose fit for the UI.
    /// `nil` when it answered — including when it answered as an old engine.
    public let failure: String?

    public init(
        version: String?,
        controlSocket: Bool,
        configCLI: Bool,
        devicesCLI: Bool,
        failure: String? = nil
    ) {
        self.version = version
        self.controlSocket = controlSocket
        self.configCLI = configCLI
        self.devicesCLI = devicesCLI
        self.failure = failure
    }

    public var isCurrent: Bool { failure == nil && controlSocket && configCLI && devicesCLI }

    /// The binary answered something. `false` means no upgrade can help —
    /// the install itself has to be repaired or replaced.
    public var isUsable: Bool { failure == nil }

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

    /// One probe invocation, kept whole rather than `try?`-flattened to nil:
    /// *how* it failed is the whole diagnosis.
    public struct ProbeRun: Sendable {
        public let launched: Bool
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let launchError: String?

        public init(
            launched: Bool, status: Int32, stdout: String, stderr: String,
            launchError: String? = nil
        ) {
            self.launched = launched
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
            self.launchError = launchError
        }
    }

    public static func probe(binary: URL) async -> EngineCapabilities {
        async let versionRun = probeRun(binary, ["--version"])
        async let runHelpRun = probeRun(binary, ["run", "--help"])
        async let mainHelpRun = probeRun(binary, ["--help"])
        let (version, runHelp, mainHelp) = await (versionRun, runHelpRun, mainHelpRun)
        let caps = parse(
            versionOutput: version.stdout,
            runHelp: runHelp.stdout,
            mainHelp: mainHelp.stdout
        )
        guard
            let failure = diagnose(
                runs: [version, runHelp, mainHelp],
                interpreter: EngineDiagnosis.shebangInterpreter(of: binary),
                interpreterExists: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return caps }
        return EngineCapabilities(
            version: caps.version,
            controlSocket: caps.controlSocket,
            configCLI: caps.configCLI,
            devicesCLI: caps.devicesCLI,
            failure: failure
        )
    }

    private static func probeRun(_ binary: URL, _ arguments: [String]) async -> ProbeRun {
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: arguments, timeout: 30)
            return ProbeRun(
                launched: true, status: result.status,
                stdout: result.stdout, stderr: result.stderr)
        } catch {
            return ProbeRun(
                launched: false, status: -1, stdout: "", stderr: "",
                launchError: error.localizedDescription)
        }
    }

    /// `nil` when the engine is usable — old counts as usable.
    public static func diagnose(
        runs: [ProbeRun],
        interpreter: String?,
        interpreterExists: (String) -> Bool
    ) -> String? {
        guard runs.contains(where: { $0.launched }) else {
            return EngineDiagnosis.launchFailure(
                interpreter: interpreter,
                interpreterExists: interpreter.map(interpreterExists) ?? false,
                error: runs.compactMap(\.launchError).first)
        }
        // It started. Anything on stdout — a version, a usage block, even an
        // error banner — is enough to keep working with.
        let spoke = runs.contains {
            !$0.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !spoke else { return nil }
        return EngineDiagnosis.silentEngine(
            status: runs.first(where: { $0.launched })?.status ?? -1,
            stderr: runs.first {
                !$0.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?.stderr)
    }
}

/// Turns an exec failure into something a person can act on.
///
/// The error macOS hands back is actively misleading for the common case: a
/// Python console script whose interpreter was deleted fails with "the file
/// doesn't exist" — naming the script, which is sitting right there. So read
/// the shebang and name the thing that is actually missing.
public enum EngineDiagnosis {
    public static func launchFailure(
        interpreter: String?, interpreterExists: Bool, error: String?
    ) -> String {
        if let interpreter, !interpreterExists {
            return "Its interpreter is gone — \(interpreter) no longer exists, "
                + "so the virtualenv behind this binary was deleted or rebuilt."
        }
        if let error, !error.isEmpty {
            return "macOS could not run it: \(error)"
        }
        return "macOS could not run it."
    }

    public static func silentEngine(status: Int32, stderr: String?) -> String {
        let detail = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detail, !detail.isEmpty else {
            return "It ran but answered nothing (exit \(status)) — the install looks incomplete."
        }
        let head = detail.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
        return "It ran but answered nothing (exit \(status)): \(head)"
    }

    /// The interpreter a `#!` line names, when the file has one.
    public static func shebangInterpreter(of binary: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return nil }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(upToCount: 512),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return interpreter(inShebangLine: text.components(separatedBy: "\n").first ?? "")
    }

    /// Pure: `#!/path/to/python` → `/path/to/python`. `/usr/bin/env python`
    /// returns nil — env resolves through PATH, so the script proves nothing
    /// about which interpreter is missing.
    public static func interpreter(inShebangLine line: String) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard
            let first = rest.split(separator: " ").first.map(String.init),
            first.hasPrefix("/"), !first.hasSuffix("/env")
        else { return nil }
        return first
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
