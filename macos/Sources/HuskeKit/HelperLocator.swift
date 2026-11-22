// Helpers Huske.app carries for the engine, and the environment every engine
// child process gets.
//
// `huske-apple-llm` (ADR 0013) lives at Huske.app/Contents/Helpers. The engine
// finds it on its own in /Applications, but a Huske.app run from anywhere else
// (a dev build in macos/dist, a copy on the Desktop) has to say where its
// helper is — so both `huske run` (EngineProcess) and one-shot CLI calls
// (CLIRunner: `llm status`, `llm test`, `inbox process`) get
// HUSKE_APPLE_LLM_HELPER pointing into this bundle, unless the caller's own
// environment already chose one.

import Foundation

public enum HelperLocator {
    public static let appleLLMVariable = "HUSKE_APPLE_LLM_HELPER"
    public static let appleLLMName = "huske-apple-llm"

    /// `<bundle>/Contents/Helpers/huske-apple-llm` when it is there and
    /// executable. A `swift run` binary has no such directory, so this is nil
    /// outside a packaged app — which is the point.
    public static func appleLLMHelper(
        inBundle bundleURL: URL,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let url = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(appleLLMName, isDirectory: false)
        return isExecutable(url.path) ? url : nil
    }

    /// The helper inside the running app, resolved once.
    public static let bundledAppleLLMHelper: URL? = appleLLMHelper(inBundle: Bundle.main.bundleURL)

    /// Environment for an engine child process. Pure, so the composition is
    /// testable: `base` is inherited, update checks are silenced (the app has
    /// its own), the helper is injected only when `base` does not already name
    /// one, and `overrides` win over everything.
    public static func childEnvironment(
        base: [String: String],
        helper: URL?,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        if let helper, (env[appleLLMVariable] ?? "").isEmpty {
            env[appleLLMVariable] = helper.path
        }
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }

    /// `childEnvironment` for this process and this app bundle.
    public static func childEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        childEnvironment(
            base: ProcessInfo.processInfo.environment,
            helper: bundledAppleLLMHelper,
            overrides: overrides)
    }
}
