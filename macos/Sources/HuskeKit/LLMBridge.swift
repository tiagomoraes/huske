// Transcript cleanup through `huske llm …` and `huske languages`.
//
// The app is a shell over the engine (ADR 0006): which providers exist, what
// "ready" means, where keys live and what may leave the Mac are all decided by
// the engine. This file only decodes its `--json` answers and runs its
// commands. Decoding is lenient on purpose — a field an older or newer engine
// leaves out falls back to a neutral default instead of failing the pane —
// and the words the engine writes (`detail`, `hint`, `error`) are passed
// through for the UI to show verbatim.

import Foundation

public enum CleanupPlacement: String, Sendable, Equatable {
    /// Runs on this Mac's own hardware (Apple Intelligence, built-in model).
    case onDevice = "on_device"
    /// A server on this Mac or the local network (Ollama, LM Studio).
    case local
    /// A cloud provider: transcript text leaves the Mac.
    case cloud
}

public struct LLMProviderInfo: Equatable, Sendable, Identifiable {
    public let name: String
    public let label: String
    public let placement: CleanupPlacement
    public let needsKey: Bool
    public let defaultModel: String?
    public let defaultEndpoint: String?

    public var id: String { name }

    public init(
        name: String, label: String, placement: CleanupPlacement, needsKey: Bool,
        defaultModel: String? = nil, defaultEndpoint: String? = nil
    ) {
        self.name = name
        self.label = label
        self.placement = placement
        self.needsKey = needsKey
        self.defaultModel = defaultModel
        self.defaultEndpoint = defaultEndpoint
    }

    /// Providers that take a URL (`distill_endpoint`). Named cloud providers
    /// always use their official endpoint, so they never show the field.
    public static let endpointProviders: Set<String> = ["ollama", "openai_compatible"]
}

/// Apple Intelligence on this Mac, as the helper reports it.
public struct AppleLLMAvailability: Equatable, Sendable {
    public var available: Bool
    public var reason: String?
    public var detail: String
    public var hint: String?
    public var contextSize: Int?
    public var helper: String?

    public init(
        available: Bool = false, reason: String? = nil, detail: String = "",
        hint: String? = nil, contextSize: Int? = nil, helper: String? = nil
    ) {
        self.available = available
        self.reason = reason
        self.detail = detail
        self.hint = hint
        self.contextSize = contextSize
        self.helper = helper
    }
}

/// `huske llm status --json`.
public struct LLMStatus: Equatable, Sendable {
    public var enabled = false
    public var backend = ""
    public var label = ""
    public var placement: CleanupPlacement = .onDevice
    public var leavesMac = false
    public var host: String?
    public var endpoint: String?
    public var model: String?
    /// Sending is allowed — or not needed, for anything that stays on the Mac.
    public var consent = true
    public var keyRequired = false
    public var keyAccepted = false
    public var keyPresent = false
    public var ready = false
    /// Machine code (`ready`, `needs_key`, `needs_consent`, `unreachable`, …).
    public var reason = "unknown"
    /// One plain sentence; shown verbatim.
    public var detail = ""
    /// The way out, when there is one; shown verbatim.
    public var hint: String?
    public var contextTokens: Int?
    /// Which providers have a key in the Keychain (`{provider: present}`).
    /// Its keys are exactly the providers that accept one.
    public var keys: [String: Bool] = [:]
    public var apple: AppleLLMAvailability?
    public var providers: [LLMProviderInfo] = []

    public init() {}

    public func provider(named name: String) -> LLMProviderInfo? {
        providers.first { $0.name == name }
    }

    /// Reasons the Configuration pane resolves with a control right there
    /// (key field, consent button, model picker), so the engine's "run this
    /// command" hint would only be noise.
    public static let inlineReasons: Set<String> = ["needs_key", "needs_consent", "needs_model"]

    /// Not ready because a step is still to be taken, rather than because
    /// something is broken.
    public var awaitingSetup: Bool {
        !ready
            && (Self.inlineReasons.contains(reason)
                || ["not_enabled", "model_not_ready"].contains(reason))
    }
}

/// `huske llm models --json`.
public struct LLMModelList: Equatable, Sendable {
    public var backend: String?
    public var models: [String]
    public var error: String?

    public init(backend: String? = nil, models: [String] = [], error: String? = nil) {
        self.backend = backend
        self.models = models
        self.error = error
    }
}

/// `huske llm test --json` — a built-in synthetic sample, never a transcript.
public struct LLMTestResult: Equatable, Sendable {
    public var ok = false
    public var label: String?
    public var input: [String] = []
    public var output: [String] = []
    public var changed = 0
    public var keptRaw = 0
    public var seconds: Double?
    public var error: String?
    /// Failure class (`auth`, `consent`, `transport`, …) when `ok` is false.
    public var kind: String?

    public init() {}

    /// Before/after pairs, as many as both sides have.
    public var pairs: [(before: String, after: String)] {
        zip(input, output).map { ($0, $1) }
    }
}

/// `huske llm key set|remove --json`.
public struct LLMKeyResult: Equatable, Sendable {
    public var provider: String?
    /// `saved` for `set`, `removed` for `remove`.
    public var done: Bool
    public var error: String?

    public init(provider: String? = nil, done: Bool = false, error: String? = nil) {
        self.provider = provider
        self.done = done
        self.error = error
    }
}

/// `huske llm allow-cloud --json`.
public struct LLMConsentResult: Equatable, Sendable {
    /// The host now allowed, or nil after a revoke.
    public var consent: String?
    public var error: String?

    public init(consent: String? = nil, error: String? = nil) {
        self.consent = consent
        self.error = error
    }
}

/// One row of `huske languages --json`.
public struct LanguageInfo: Equatable, Sendable, Identifiable {
    public let code: String
    public let name: String
    /// `pinned` — Whisper takes the language as an input.
    public let whisper: String
    /// `detected` or `unsupported` — Parakeet infers the language itself.
    public let parakeet: String

    public var id: String { code }
    public var parakeetSupported: Bool { parakeet != "unsupported" }

    public init(code: String, name: String, whisper: String = "pinned", parakeet: String) {
        self.code = code
        self.name = name
        self.whisper = whisper
        self.parakeet = parakeet
    }

    /// Parakeet TDT 0.6B v3's 25 European languages — the fallback when the
    /// engine predates `huske languages`.
    public static let parakeetCodes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]
}

public enum LLMBridgeError: Error, Equatable {
    /// The engine answered something that is not the expected JSON object.
    case badOutput(String)
}

public enum LLMBridge {
    // MARK: decoding (pure)

    public static func parseStatus(_ text: String) throws -> LLMStatus {
        let obj = try object(from: text)
        var status = LLMStatus()
        status.enabled = bool(obj["enabled"]) ?? false
        status.backend = string(obj["backend"]) ?? ""
        status.label = string(obj["label"]) ?? status.backend
        status.placement = string(obj["placement"]).flatMap(CleanupPlacement.init) ?? .onDevice
        status.leavesMac = bool(obj["leaves_mac"]) ?? (status.placement == .cloud)
        status.host = string(obj["host"])
        status.endpoint = string(obj["endpoint"])
        status.model = string(obj["model"])
        status.consent = bool(obj["consent"]) ?? !status.leavesMac
        status.keyRequired = bool(obj["key_required"]) ?? false
        status.keyAccepted = bool(obj["key_accepted"]) ?? false
        status.keyPresent = bool(obj["key_present"]) ?? false
        status.ready = bool(obj["ready"]) ?? false
        status.reason = string(obj["reason"]) ?? (status.ready ? "ready" : "unknown")
        status.detail = string(obj["detail"]) ?? ""
        status.hint = string(obj["hint"])
        status.contextTokens = int(obj["context_tokens"])
        if let keys = obj["keys"] as? [String: Any] {
            status.keys = keys.compactMapValues { bool($0) }
        }
        if let apple = obj["apple"] as? [String: Any] {
            status.apple = AppleLLMAvailability(
                available: bool(apple["available"]) ?? false,
                reason: string(apple["reason"]),
                detail: string(apple["detail"]) ?? "",
                hint: string(apple["hint"]),
                contextSize: int(apple["context_size"]),
                helper: string(apple["helper"]))
        }
        if let providers = obj["providers"] as? [[String: Any]] {
            status.providers = providers.compactMap { row in
                guard let name = string(row["name"]) else { return nil }
                return LLMProviderInfo(
                    name: name,
                    label: string(row["label"]) ?? name,
                    placement: string(row["placement"]).flatMap(CleanupPlacement.init) ?? .local,
                    needsKey: bool(row["needs_key"]) ?? false,
                    defaultModel: string(row["default_model"]),
                    defaultEndpoint: string(row["default_endpoint"]))
            }
        }
        return status
    }

    public static func parseModels(_ text: String) throws -> LLMModelList {
        let obj = try object(from: text)
        return LLMModelList(
            backend: string(obj["backend"]),
            models: (obj["models"] as? [Any])?.compactMap { string($0) } ?? [],
            error: string(obj["error"]))
    }

    public static func parseTest(_ text: String) throws -> LLMTestResult {
        let obj = try object(from: text)
        var result = LLMTestResult()
        result.error = string(obj["error"])
        result.ok = bool(obj["ok"]) ?? (result.error == nil)
        result.label = string(obj["label"])
        result.input = (obj["input"] as? [Any])?.compactMap { string($0) } ?? []
        result.output = (obj["output"] as? [Any])?.compactMap { string($0) } ?? []
        result.changed = int(obj["changed"]) ?? 0
        result.keptRaw = int(obj["kept_raw"]) ?? 0
        result.seconds = double(obj["seconds"])
        result.kind = string(obj["kind"])
        return result
    }

    /// `field` is `saved` (key set) or `removed` (key remove).
    public static func parseKeyResult(_ text: String, field: String) throws -> LLMKeyResult {
        let obj = try object(from: text)
        return LLMKeyResult(
            provider: string(obj["provider"]),
            done: bool(obj[field]) ?? false,
            error: string(obj["error"]))
    }

    public static func parseKeyList(_ text: String) throws -> [String: Bool] {
        let obj = try object(from: text)
        return (obj["keys"] as? [String: Any])?.compactMapValues { bool($0) } ?? [:]
    }

    public static func parseConsent(_ text: String) throws -> LLMConsentResult {
        let obj = try object(from: text)
        return LLMConsentResult(consent: string(obj["consent"]), error: string(obj["error"]))
    }

    public static func parseLanguages(_ text: String) throws -> [LanguageInfo] {
        let obj = try object(from: text)
        guard let rows = obj["languages"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let code = string(row["code"]) else { return nil }
            return LanguageInfo(
                code: code,
                name: string(row["name"]) ?? code,
                whisper: string(row["whisper"]) ?? "pinned",
                parakeet: string(row["parakeet"])
                    ?? (LanguageInfo.parakeetCodes.contains(code) ? "detected" : "unsupported"))
        }
    }

    // MARK: commands

    public static func status(binary: URL, backend: String? = nil) async throws -> LLMStatus {
        var args = ["llm", "status", "--json"]
        if let backend { args += ["--backend", backend] }
        // The status probe may ask a local server for its models; bounded.
        return try parseStatus(try await output(binary, args, timeout: 30))
    }

    public static func models(binary: URL, backend: String? = nil) async throws -> LLMModelList {
        var args = ["llm", "models", "--json"]
        if let backend { args += ["--backend", backend] }
        return try parseModels(try await output(binary, args, timeout: 45))
    }

    /// Cleans up the engine's own two-line synthetic sample. Generous timeout:
    /// the first run of the built-in model downloads it.
    public static func test(binary: URL) async throws -> LLMTestResult {
        try parseTest(try await output(binary, ["llm", "test", "--json"], timeout: 900))
    }

    /// Store an API key. The key goes to the engine on stdin — never as an
    /// argument — and the bytes handed over are wiped once it has answered.
    public static func saveKey(binary: URL, provider: String, key: String) async throws -> LLMKeyResult {
        var secret = Data(key.utf8)
        secret.append(0x0A)
        defer { secret.resetBytes(in: 0..<secret.count) }
        let result = try await CLIRunner.run(
            binary: binary, arguments: ["llm", "key", "set", provider, "--json"],
            stdin: secret, timeout: 30)
        return try parseKeyResult(try json(from: result), field: "saved")
    }

    public static func removeKey(binary: URL, provider: String) async throws -> LLMKeyResult {
        try parseKeyResult(
            try await output(binary, ["llm", "key", "remove", provider, "--json"], timeout: 30),
            field: "removed")
    }

    /// Allow sending transcripts to the *configured* provider's host — so the
    /// backend must already be written before this runs.
    public static func allowCloud(binary: URL) async throws -> LLMConsentResult {
        try parseConsent(try await output(binary, ["llm", "allow-cloud", "--yes", "--json"]))
    }

    public static func revokeCloud(binary: URL) async throws -> LLMConsentResult {
        try parseConsent(try await output(binary, ["llm", "allow-cloud", "--revoke", "--json"]))
    }

    public static func languages(binary: URL) async throws -> [LanguageInfo] {
        try parseLanguages(try await output(binary, ["languages", "--json"]))
    }

    // MARK: helpers

    /// Failures still answer with JSON (`{"error": …}`, exit 1/2), so the exit
    /// status is not a reason to stop reading.
    private static func output(
        _ binary: URL, _ arguments: [String], timeout: TimeInterval = 60
    ) async throws -> String {
        let result = try await CLIRunner.run(binary: binary, arguments: arguments, timeout: timeout)
        return try json(from: result)
    }

    private static func json(from result: CLIResult) throws -> String {
        if (try? object(from: result.stdout)) != nil { return result.stdout }
        let said = (result.stderr + "\n" + result.stdout)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        throw LLMBridgeError.badOutput(
            said ?? "the engine gave no answer (exit \(result.status))")
    }

    /// The JSON object in `text` — the whole of it, or else its last line that
    /// is one (a stray progress line must not hide the answer).
    static func object(from text: String) throws -> [String: Any] {
        if let obj = decodeObject(text) { return obj }
        for line in text.split(separator: "\n").reversed()
        where line.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            if let obj = decodeObject(String(line)) { return obj }
        }
        throw LLMBridgeError.badOutput("expected a JSON object from the engine")
    }

    private static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        return s
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }
}

// MARK: - words for the Configuration pane (pure, so they are tested)

public enum CleanupWords {
    static let cloudProviders: Set<String> = ["openai", "anthropic", "openrouter"]

    /// "apple:apple-on-device" → "Apple Intelligence";
    /// "anthropic:claude-haiku-5-5" → "Anthropic · claude-haiku-5-5".
    /// Only the first colon separates provider from model (Ollama tags have
    /// their own). Cloud providers name the model too — it is the one whose
    /// terms the text went to.
    public static func provenance(postprocessedBy raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let provider: String
        let model: String
        if let colon = trimmed.firstIndex(of: ":") {
            provider = String(trimmed[..<colon])
            model = String(trimmed[trimmed.index(after: colon)...])
        } else {
            provider = trimmed
            model = ""
        }
        let label: String
        switch provider {
        case "apple": label = "Apple Intelligence"
        case "mlx": label = "the built-in model"
        case "ollama": label = "Ollama"
        case "openai_compatible": label = "a local server"
        case "openai": label = "OpenAI"
        case "anthropic": label = "Anthropic"
        case "openrouter": label = "OpenRouter"
        default: label = provider
        }
        if cloudProviders.contains(provider), !model.isEmpty, model != "default" {
            return "\(label) · \(model)"
        }
        return label
    }

    /// The line under the Language picker: what the chosen engine actually
    /// does with the setting.
    public static func languageNote(
        engine: String, code: String, languages: [LanguageInfo]
    ) -> String {
        let code = code.trimmingCharacters(in: .whitespaces).lowercased()
        if engine == "whisper" {
            return code.isEmpty
                ? "Whisper works out the language of each recording on its own."
                : "Whisper transcribes in this language only."
        }
        let lock = "To lock the language, switch to Whisper (large-v3-turbo)."
        guard !code.isEmpty else {
            return "Parakeet works out the language as it goes. Choose one here to catch "
                + "stretches that slip into English. \(lock)"
        }
        let known = languages.first { $0.code == code }
        let supported = known?.parakeetSupported ?? LanguageInfo.parakeetCodes.contains(code)
        if !supported {
            let name = known?.name ?? languageName(code)
            return "Parakeet doesn't understand \(name). To transcribe it, "
                + "switch to Whisper (large-v3-turbo)."
        }
        if code == "en" {
            return "Parakeet can't be told the language — it works it out as it goes. \(lock)"
        }
        return "Parakeet can't be told the language — it works it out as it goes. Huske uses "
            + "this setting to catch stretches that slip into English and redo them. \(lock)"
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Words for the Dictionary editor: one entry per line, trimmed, empties
    /// and repeats dropped, order kept (it is a priority order).
    public static func vocabulary(fromLines text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let word = line.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !seen.contains(word) else { continue }
            seen.insert(word)
            out.append(word)
        }
        return out
    }

    /// Corrections from editor rows: both sides trimmed, half-filled rows
    /// skipped (they are still being typed).
    public static func replacements(fromRows rows: [(heard: String, written: String)]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            let heard = row.heard.trimmingCharacters(in: .whitespaces)
            let written = row.written.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !written.isEmpty else { continue }
            out[heard] = written
        }
        return out
    }

    /// "1.6s", "12s" — the test's duration, set in mono like every other
    /// duration in the app ("60s", "14m 0s"), where a space would gape.
    public static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1fs", value) : String(format: "%.0fs", value)
    }

    /// Engine messages start lower-case ("no OpenAI API key…"); the UI shows
    /// them as sentences.
    public static func sentence(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
