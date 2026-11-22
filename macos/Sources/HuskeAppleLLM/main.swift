// huske-apple-llm — Apple Intelligence for the huske engine (ADR 0013).
//
// A small command-line helper bundled at Huske.app/Contents/Helpers. The
// Python engine spawns it and speaks the JSON-line protocol in
// HuskeAppleLLMCore. It holds no pipeline logic: chunking, prompts,
// validation and fallbacks all live in the engine.
//
//   huske-apple-llm            serve requests on stdin/stdout
//   huske-apple-llm --status   print availability as one JSON line and exit
//   huske-apple-llm --version  print the protocol version
//
// Built against an SDK without FoundationModels (the CI runner's Xcode 16),
// it still compiles and answers every request with `not_built`, so the
// engine can say plainly why Apple Intelligence isn't offered.

import Foundation
import HuskeAppleLLMCore

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
struct FoundationModel: HelperModel {
    func status(locale: String?) async -> ModelStatus {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        var status = ModelStatus(available: false, contextSize: Self.contextSize(model))
        switch model.availability {
        case .available:
            status.available = true
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: status.reason = .deviceNotEligible
            case .appleIntelligenceNotEnabled: status.reason = .notEnabled
            case .modelNotReady: status.reason = .modelNotReady
            @unknown default: status.reason = .unknown
            }
        }
        if let locale, !locale.isEmpty {
            status.localeSupported = model.supportsLocale(Locale(identifier: locale))
        }
        return status
    }

    func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        // Permissive guardrails are Apple's mode for transforming text the
        // user supplied: a meeting transcript can mention anything, and a
        // default-guardrail refusal would only cost a cleanup, not safety.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        if case .unavailable(let reason) = model.availability {
            throw HelperFailure(.unavailable, "Apple Intelligence is unavailable (\(reason))")
        }
        // A fresh session per request: the engine sends self-contained
        // chunks, and a session's transcript would otherwise eat the context.
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, options: Self.options(maxTokens))
        return response.content
    }

    private static func options(_ maxTokens: Int) -> GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        #endif
    }

    private static func contextSize(_ model: SystemLanguageModel) -> Int {
        // 4,096 tokens on macOS 26 (TN3193); macOS 27 reports the real value
        // (8,192 on AFM 3 Core Advanced). The property arrived in a later SDK.
        #if compiler(>=6.4)
        return model.contextSize
        #else
        return 4096
        #endif
    }
}
#endif

struct UnavailableModel: HelperModel {
    let reason: UnavailableReason

    func status(locale: String?) async -> ModelStatus {
        ModelStatus(available: false, reason: reason)
    }

    func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        throw HelperFailure(.unavailable, "Apple Intelligence is unavailable (\(reason.rawValue))")
    }
}

func makeModel() -> any HelperModel {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        return FoundationModel()
    }
    return UnavailableModel(reason: .osTooOld)
    #else
    return UnavailableModel(reason: .notBuilt)
    #endif
}

let arguments = CommandLine.arguments.dropFirst()
let server = HelperServer(model: makeModel())

if arguments.contains("--version") {
    print("huske-apple-llm protocol \(helperProtocolVersion)")
} else if arguments.contains("--status") {
    let localeIndex = arguments.firstIndex(of: "--locale")
    let locale = localeIndex.flatMap { arguments.index(after: $0) < arguments.endIndex ? arguments[arguments.index(after: $0)] : nil }
    let status = await server.model.status(locale: locale)
    print(HelperReply.status(id: 0, status))
} else {
    await server.serve()
}
