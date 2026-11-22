import Foundation
import XCTest

@testable import HuskeAppleLLMCore

private struct FakeModel: HelperModel {
    var status = ModelStatus(available: true, contextSize: 8192, localeSupported: true)
    var reply: Result<String, HelperFailure> = .success("[1] Olá.")
    var thrown: (any Error & Sendable)?

    func status(locale: String?) async -> ModelStatus { status }

    func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        if let thrown { throw thrown }
        return try reply.get()
    }
}

/// Stand-ins whose reflected names match the real error families.
private enum GenerationError: Error { case exceededContextWindowSize, guardrailViolation, rateLimited }
private enum LanguageModelError: Error { case contextSizeExceeded(contextSize: Int, tokenCount: Int), refusal }

final class HelperProtocolTests: XCTestCase {
    private func decode(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStatusReportsAvailabilityContextAndLocale() async throws {
        let server = HelperServer(model: FakeModel())
        let reply = try decode(await server.handle(line: #"{"id":7,"op":"status","locale":"pt"}"#))
        XCTAssertEqual(reply["id"] as? Int, 7)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["available"] as? Bool, true)
        XCTAssertEqual(reply["context_size"] as? Int, 8192)
        XCTAssertEqual(reply["locale_supported"] as? Bool, true)
        XCTAssertEqual(reply["protocol"] as? Int, helperProtocolVersion)
        XCTAssertNil(reply["reason"])
    }

    func testUnavailableStatusCarriesTheReason() async throws {
        let model = FakeModel(status: ModelStatus(available: false, reason: .notEnabled))
        let reply = try decode(await HelperServer(model: model).handle(line: #"{"id":1,"op":"status"}"#))
        XCTAssertEqual(reply["available"] as? Bool, false)
        XCTAssertEqual(reply["reason"] as? String, "not_enabled")
    }

    func testRespondReturnsText() async throws {
        let line = #"{"id":2,"op":"respond","instructions":"rules","prompt":"[1] ola","max_tokens":100}"#
        let reply = try decode(await HelperServer(model: FakeModel()).handle(line: line))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["text"] as? String, "[1] Olá.")
    }

    func testHelperFailuresPassThrough() async throws {
        let model = FakeModel(reply: .failure(HelperFailure(.unavailable, "downloading")))
        let reply = try decode(
            await HelperServer(model: model).handle(line: #"{"id":3,"op":"respond","prompt":"x"}"#))
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "unavailable")
    }

    func testFrameworkErrorsAreClassifiedByName() async throws {
        let model = FakeModel(thrown: LanguageModelError.contextSizeExceeded(contextSize: 8192, tokenCount: 9009))
        let reply = try decode(
            await HelperServer(model: model).handle(line: #"{"id":4,"op":"respond","prompt":"x"}"#))
        XCTAssertEqual(reply["error"] as? String, "context")
    }

    func testClassifierCoversBothErrorFamilies() {
        XCTAssertEqual(ErrorClassifier.classify(String(reflecting: GenerationError.exceededContextWindowSize)), .context)
        XCTAssertEqual(ErrorClassifier.classify(String(reflecting: GenerationError.guardrailViolation)), .refused)
        XCTAssertEqual(ErrorClassifier.classify(String(reflecting: GenerationError.rateLimited)), .rateLimited)
        XCTAssertEqual(ErrorClassifier.classify(String(reflecting: LanguageModelError.refusal)), .refused)
        XCTAssertEqual(ErrorClassifier.classify("SystemLanguageModel.Error.assetsUnavailable"), .unavailable)
        XCTAssertEqual(ErrorClassifier.classify("LanguageModelSession.Error.concurrentRequests"), .busy)
        XCTAssertEqual(ErrorClassifier.classify("something new"), .failed)
    }

    func testBadInputIsAnsweredNotFatal() async throws {
        let server = HelperServer(model: FakeModel())
        let blank = await server.handle(line: "   ")
        XCTAssertNil(blank)
        let garbage = try decode(await server.handle(line: "not json"))
        XCTAssertEqual(garbage["error"] as? String, "bad_request")
        let missing = try decode(await server.handle(line: #"{"id":5,"op":"respond"}"#))
        XCTAssertEqual(missing["error"] as? String, "bad_request")
        let unknown = try decode(await server.handle(line: #"{"id":6,"op":"dance"}"#))
        XCTAssertEqual(unknown["error"] as? String, "bad_request")
    }
}
