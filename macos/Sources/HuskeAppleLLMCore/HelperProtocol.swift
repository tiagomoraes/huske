// The wire contract between the Python engine and `huske-apple-llm`, the
// helper inside Huske.app that runs Apple's on-device Foundation Models
// (ADR 0013). Pipeline logic stays in the engine (ADR 0006): this side only
// answers "is the model usable?" and "complete this prompt".
//
// One JSON object per line on stdin, one reply per line on stdout:
//
//   {"id":1,"op":"status","locale":"pt"}
//   {"id":1,"ok":true,"available":true,"context_size":8192,"locale_supported":true}
//
//   {"id":2,"op":"respond","instructions":"…","prompt":"…","max_tokens":900}
//   {"id":2,"ok":true,"text":"…"}
//   {"id":2,"ok":false,"error":"context","message":"…"}
//
// Requests are served strictly one at a time: the on-device model queues
// concurrent sessions anyway, and one session rejects overlapping calls.
//
// Deliberately free of FoundationModels so it builds (and is tested) with any
// SDK, including the CI runner's, which predates the framework.

import Foundation

public let helperProtocolVersion = 1

public struct HelperRequest: Decodable, Equatable, Sendable {
    public let id: Int
    public let op: String
    public var locale: String?
    public var instructions: String?
    public var prompt: String?
    public var maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case id, op, locale, instructions, prompt
        case maxTokens = "max_tokens"
    }

    public init(
        id: Int, op: String, locale: String? = nil, instructions: String? = nil,
        prompt: String? = nil, maxTokens: Int? = nil
    ) {
        self.id = id
        self.op = op
        self.locale = locale
        self.instructions = instructions
        self.prompt = prompt
        self.maxTokens = maxTokens
    }
}

/// Why Apple Intelligence can't be used, as the engine and the app explain it.
public enum UnavailableReason: String, Codable, Sendable, CaseIterable {
    /// `SystemLanguageModel.UnavailableReason.deviceNotEligible`.
    case deviceNotEligible = "device_not_eligible"
    /// `.appleIntelligenceNotEnabled` — turned off in System Settings.
    case notEnabled = "not_enabled"
    /// `.modelNotReady` — usually still downloading.
    case modelNotReady = "model_not_ready"
    /// macOS older than 26.
    case osTooOld = "os_too_old"
    /// This helper was built with an SDK that has no FoundationModels.
    case notBuilt = "not_built"
    /// A reason this helper doesn't know yet (a newer OS).
    case unknown
}

/// Error classes the engine branches on (mirrors `ErrorKind` in
/// `huske/distill/client.py`).
public enum HelperErrorKind: String, Codable, Sendable {
    case context
    case refused
    case rateLimited = "rate_limited"
    case unavailable
    case unsupportedLanguage = "unsupported_language"
    case busy
    case timeout
    case badRequest = "bad_request"
    case failed
}

public struct ModelStatus: Equatable, Sendable {
    public var available: Bool
    public var reason: UnavailableReason?
    public var contextSize: Int
    public var localeSupported: Bool?

    public init(
        available: Bool, reason: UnavailableReason? = nil, contextSize: Int = 4096,
        localeSupported: Bool? = nil
    ) {
        self.available = available
        self.reason = reason
        self.contextSize = contextSize
        self.localeSupported = localeSupported
    }
}

public struct HelperFailure: Error, Equatable, Sendable {
    public let kind: HelperErrorKind
    public let message: String

    public init(_ kind: HelperErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// The model behind the helper: Foundation Models in the shipped binary, a
/// fake in tests, a stub when the SDK lacks the framework.
public protocol HelperModel: Sendable {
    func status(locale: String?) async -> ModelStatus
    func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String
}

public enum HelperReply {
    public static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func status(id: Int, _ status: ModelStatus) -> String {
        var object: [String: Any] = [
            "id": id,
            "ok": true,
            "available": status.available,
            "context_size": status.contextSize,
            "protocol": helperProtocolVersion,
        ]
        if let reason = status.reason { object["reason"] = reason.rawValue }
        if let supported = status.localeSupported { object["locale_supported"] = supported }
        return encode(object)
    }

    public static func text(id: Int, _ text: String) -> String {
        encode(["id": id, "ok": true, "text": text])
    }

    public static func failure(id: Int, _ failure: HelperFailure) -> String {
        encode(["id": id, "ok": false, "error": failure.kind.rawValue, "message": failure.message])
    }
}

/// Maps any Foundation Models error to a `HelperErrorKind` by its reflected
/// name. macOS 26 throws `LanguageModelSession.GenerationError`; macOS 27
/// replaced it with `LanguageModelError` and friends — and a binary built
/// against one SDK sees the other's type at run time, so `as?` casts miss.
/// The case names are the stable part, so match those.
public enum ErrorClassifier {
    public static func classify(_ reflected: String) -> HelperErrorKind {
        let name = reflected.lowercased()
        if name.contains("exceededcontextwindowsize") || name.contains("contextsizeexceeded") {
            return .context
        }
        if name.contains("guardrailviolation") || name.contains("refusal") {
            return .refused
        }
        if name.contains("ratelimited") { return .rateLimited }
        if name.contains("assetsunavailable") { return .unavailable }
        if name.contains("unsupportedlanguageorlocale") { return .unsupportedLanguage }
        if name.contains("concurrentrequests") || name.contains("transcriptmutationwhileresponding") {
            return .busy
        }
        if name.contains("timeout") { return .timeout }
        return .failed
    }
}

/// Reads request lines, answers each in order. `handle` is the unit-tested
/// core; `serve` wires it to stdin/stdout.
public struct HelperServer: Sendable {
    public let model: any HelperModel

    public init(model: any HelperModel) {
        self.model = model
    }

    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data)
        else {
            return HelperReply.failure(id: 0, HelperFailure(.badRequest, "not a request object"))
        }
        switch request.op {
        case "status":
            return HelperReply.status(id: request.id, await model.status(locale: request.locale))
        case "respond":
            guard let prompt = request.prompt, !prompt.isEmpty else {
                return HelperReply.failure(id: request.id, HelperFailure(.badRequest, "missing prompt"))
            }
            let maxTokens = max(16, min(request.maxTokens ?? 1024, 8192))
            do {
                let text = try await model.respond(
                    instructions: request.instructions ?? "", prompt: prompt, maxTokens: maxTokens)
                return HelperReply.text(id: request.id, text)
            } catch let failure as HelperFailure {
                return HelperReply.failure(id: request.id, failure)
            } catch {
                let kind = ErrorClassifier.classify(String(reflecting: error))
                return HelperReply.failure(
                    id: request.id, HelperFailure(kind, String(describing: error).prefix(300).description))
            }
        default:
            return HelperReply.failure(
                id: request.id, HelperFailure(.badRequest, "unknown op \(request.op)"))
        }
    }

    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { return }  // EOF: the engine went away
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                if let reply = await handle(line: line) {
                    output.write(Data((reply + "\n").utf8))
                }
            }
        }
    }
}
