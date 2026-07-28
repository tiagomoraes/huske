// Runs `huske setup --json` / `huske setup --apply <target>` and models the
// result for the Connect pane.
//
// All of the judgement — which step is blocked, which command fixes it, whether
// a client can be wired without a terminal — lives in `huske/setup.py`. This
// file only decodes and forwards, so the app and the CLI can never disagree
// about the state of someone's setup (ADR 0006).

import Foundation

public enum SetupState: String, Sendable, Equatable {
    /// Done.
    case ok
    /// Not done, and the user (or `apply`) can do it now.
    case todo
    /// Not done and nothing else can proceed until it is.
    case blocked
    /// Not required — an uninstalled client, or the off-by-default connector.
    case optional

    /// Unknown values decode as `optional` so a newer engine adding a state
    /// cannot make an older app render a broken row.
    init(lenient raw: String) {
        self = SetupState(rawValue: raw) ?? .optional
    }
}

public struct SetupStep: Equatable, Sendable, Identifiable {
    public let key: String
    public let title: String
    public let state: SetupState
    public let detail: String
    /// A shell command that completes this step, when one exists.
    public let fix: String?
    /// True when `huske setup --apply <key>` finishes it with no terminal.
    public let canApply: Bool

    public var id: String { key }

    public init(
        key: String, title: String, state: SetupState, detail: String, fix: String?,
        canApply: Bool
    ) {
        self.key = key
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
        self.canApply = canApply
    }
}

public struct SetupReport: Equatable, Sendable {
    /// True only when an LLM on this Mac can search *right now* — extra
    /// installed, transcripts indexed, and the server listening.
    public let ready: Bool
    public let endpoint: String
    public let connectorURL: String?
    public let steps: [SetupStep]

    public init(ready: Bool, endpoint: String, connectorURL: String?, steps: [SetupStep]) {
        self.ready = ready
        self.endpoint = endpoint
        self.connectorURL = connectorURL
        self.steps = steps
    }

    public func step(_ key: String) -> SetupStep? {
        steps.first { $0.key == key }
    }

    /// Steps the pane offers a button for, in the order they must happen.
    public var actionable: [SetupStep] {
        steps.filter { $0.state == .todo || $0.state == .blocked }
    }
}

public enum SetupBridgeError: Error, Equatable {
    case commandFailed(String)
    case badOutput
}

public enum SetupBridge {
    public static func load(binary: URL) async throws -> SetupReport {
        // Exit 1 means "not ready yet", which is a normal state with a full
        // report attached — so parseable output always wins over the status.
        let result = try await CLIRunner.run(
            binary: binary, arguments: ["setup", "--json"], timeout: 60)
        if let report = try? parse(result.stdout) {
            return report
        }
        let detail = EngineOutput.sanitize((result.stderr + result.stdout).components(
            separatedBy: "\n"))
        throw SetupBridgeError.commandFailed(
            detail.isEmpty ? "setup produced no output" : detail)
    }

    static func parse(_ text: String) throws -> SetupReport {
        guard let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stepsRaw = obj["steps"] as? [[String: Any]]
        else {
            throw SetupBridgeError.badOutput
        }
        let steps: [SetupStep] = stepsRaw.compactMap { raw in
            guard let key = raw["key"] as? String,
                let title = raw["title"] as? String
            else { return nil }
            return SetupStep(
                key: key,
                title: title,
                state: SetupState(lenient: raw["state"] as? String ?? ""),
                detail: raw["detail"] as? String ?? "",
                fix: raw["fix"] as? String,
                canApply: raw["can_apply"] as? Bool ?? false
            )
        }
        return SetupReport(
            ready: obj["ready"] as? Bool ?? false,
            endpoint: obj["endpoint"] as? String ?? "",
            connectorURL: obj["connector_url"] as? String,
            steps: steps
        )
    }

    /// Complete one step. Streams the engine's output so a long `index` shows
    /// progress instead of a frozen button.
    public static func apply(
        binary: URL,
        target: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        let status = try await CLIRunner.stream(
            binary: binary, arguments: ["setup", "--apply", target], onLine: onLine)
        return status == 0
    }
}
