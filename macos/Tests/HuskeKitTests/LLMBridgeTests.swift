import XCTest

@testable import HuskeKit

/// `huske llm … --json` and `huske languages --json`, decoded from samples
/// shaped exactly like the engine's output (taken from a real run).
final class LLMBridgeTests: XCTestCase {
    private let appleReady = """
        {"enabled": false, "backend": "apple", "label": "Apple Intelligence", "placement": "on_device",
         "leaves_mac": false, "host": null, "endpoint": null, "model": "apple-on-device",
         "consent": true, "key_required": false, "key_accepted": false, "key_present": false,
         "ready": true, "reason": "ready",
         "detail": "Apple Intelligence is ready (8,192-token context)", "hint": null,
         "context_tokens": 8192,
         "keys": {"openai_compatible": false, "openai": false, "anthropic": false, "openrouter": false},
         "apple": {"available": true, "reason": null, "detail": "Apple Intelligence is ready on this Mac.",
                   "hint": null, "context_size": 8192, "helper": "/Applications/Huske.app/Contents/Helpers/huske-apple-llm"},
         "providers": [
           {"name": "mlx", "label": "Built-in model", "placement": "on_device", "needs_key": false,
            "default_model": "mlx-community/Qwen3.5-0.8B-4bit", "default_endpoint": null},
           {"name": "openai_compatible", "label": "OpenAI-compatible server", "placement": "local",
            "needs_key": false, "default_model": null, "default_endpoint": "http://127.0.0.1:1234/v1"},
           {"name": "anthropic", "label": "Anthropic", "placement": "cloud", "needs_key": true,
            "default_model": "claude-haiku-5-5", "default_endpoint": "https://api.anthropic.com/v1"}]}
        """

    private let openAINeedsKey = """
        {"enabled": false, "backend": "openai", "label": "OpenAI", "placement": "cloud", "leaves_mac": true,
         "host": "api.openai.com", "endpoint": "https://api.openai.com/v1", "model": null,
         "consent": false, "key_required": true, "key_accepted": true, "key_present": false,
         "ready": false, "reason": "needs_key", "detail": "no OpenAI API key in the Keychain",
         "hint": "Add it in Huske.app \\u2192 Configuration, or run `huske llm key set openai`.",
         "context_tokens": 32000,
         "keys": {"openai_compatible": false, "openai": false, "anthropic": true, "openrouter": false},
         "apple": {"available": false, "reason": "no_helper",
                   "detail": "Apple Intelligence runs through Huske.app, which wasn't found.",
                   "hint": "Install Huske.app in Applications (it carries the helper), or set HUSKE_APPLE_LLM_HELPER to the helper's path.",
                   "context_size": null, "helper": null},
         "providers": []}
        """

    // MARK: status

    func testAppleReadyStatusDecodes() throws {
        let status = try LLMBridge.parseStatus(appleReady)
        XCTAssertEqual(status.backend, "apple")
        XCTAssertEqual(status.label, "Apple Intelligence")
        XCTAssertEqual(status.placement, .onDevice)
        XCTAssertFalse(status.leavesMac)
        XCTAssertNil(status.host)
        XCTAssertEqual(status.model, "apple-on-device")
        XCTAssertTrue(status.consent)
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.reason, "ready")
        XCTAssertEqual(status.detail, "Apple Intelligence is ready (8,192-token context)")
        XCTAssertNil(status.hint)
        XCTAssertEqual(status.contextTokens, 8192)
        XCTAssertEqual(status.keys["anthropic"], false)
        XCTAssertEqual(status.keys.count, 4)
        XCTAssertEqual(status.apple?.available, true)
        XCTAssertEqual(status.apple?.contextSize, 8192)
        XCTAssertNil(status.apple?.reason)
        XCTAssertFalse(status.awaitingSetup)
        XCTAssertEqual(status.providers.map(\.name), ["mlx", "openai_compatible", "anthropic"])
        let anthropic = try XCTUnwrap(status.provider(named: "anthropic"))
        XCTAssertEqual(anthropic.placement, .cloud)
        XCTAssertTrue(anthropic.needsKey)
        XCTAssertEqual(anthropic.defaultModel, "claude-haiku-5-5")
        XCTAssertNil(status.provider(named: "openai_compatible")?.defaultModel)
        XCTAssertEqual(
            status.provider(named: "openai_compatible")?.defaultEndpoint, "http://127.0.0.1:1234/v1")
    }

    func testCloudStatusNeedingAKeyDecodes() throws {
        let status = try LLMBridge.parseStatus(openAINeedsKey)
        XCTAssertEqual(status.placement, .cloud)
        XCTAssertTrue(status.leavesMac)
        XCTAssertEqual(status.host, "api.openai.com")
        XCTAssertNil(status.model)
        XCTAssertFalse(status.consent)
        XCTAssertTrue(status.keyRequired)
        XCTAssertFalse(status.keyPresent)
        XCTAssertFalse(status.ready)
        XCTAssertEqual(status.reason, "needs_key")
        XCTAssertTrue(status.awaitingSetup)
        XCTAssertTrue(LLMStatus.inlineReasons.contains(status.reason))
        XCTAssertEqual(status.hint?.contains("→ Configuration"), true)
        XCTAssertEqual(status.keys["anthropic"], true)
        XCTAssertEqual(status.apple?.reason, "no_helper")
        XCTAssertNil(status.apple?.contextSize)
        XCTAssertTrue(status.providers.isEmpty)
    }

    func testStatusFromAnOlderEngineFallsBackToNeutralDefaults() throws {
        let status = try LLMBridge.parseStatus(#"{"backend": "ollama", "ready": false}"#)
        XCTAssertEqual(status.backend, "ollama")
        XCTAssertEqual(status.label, "ollama")
        XCTAssertEqual(status.placement, .onDevice)
        XCTAssertFalse(status.leavesMac)
        XCTAssertTrue(status.consent, "nothing leaves the Mac, so nothing needs allowing")
        XCTAssertEqual(status.reason, "unknown")
        XCTAssertEqual(status.detail, "")
        XCTAssertNil(status.apple)
        XCTAssertTrue(status.keys.isEmpty)
        XCTAssertFalse(status.awaitingSetup)
    }

    func testCloudPlacementWithoutLeavesMacStillCountsAsLeaving() throws {
        let status = try LLMBridge.parseStatus(#"{"backend": "openai", "placement": "cloud"}"#)
        XCTAssertTrue(status.leavesMac)
        XCTAssertFalse(status.consent)
    }

    func testNumbersAreNotMistakenForBooleans() throws {
        let status = try LLMBridge.parseStatus(#"{"ready": 1, "context_tokens": true}"#)
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.contextTokens)
    }

    func testAnswerAfterAStrayLineStillDecodes() throws {
        let status = try LLMBridge.parseStatus(
            "downloading model…\n" + #"{"backend": "mlx", "ready": true, "reason": "ready"}"# + "\n")
        XCTAssertEqual(status.backend, "mlx")
        XCTAssertTrue(status.ready)
    }

    func testGarbageIsBadOutput() {
        XCTAssertThrowsError(try LLMBridge.parseStatus("Traceback (most recent call last):")) {
            guard case LLMBridgeError.badOutput = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try LLMBridge.parseStatus("[1, 2]"))
        XCTAssertThrowsError(try LLMBridge.parseStatus(""))
    }

    // MARK: models

    func testModelsDecode() throws {
        let list = try LLMBridge.parseModels(
            #"{"backend": "mlx", "models": ["mlx-community/Qwen3.5-0.8B-4bit", "mlx-community/Qwen3.5-2B-4bit"], "error": null}"#)
        XCTAssertEqual(list.backend, "mlx")
        XCTAssertEqual(list.models.count, 2)
        XCTAssertNil(list.error)
    }

    func testModelsFailureKeepsTheEnginesWords() throws {
        let list = try LLMBridge.parseModels(
            #"{"error": "add an API key for OpenAI first (`huske llm key set openai`)", "models": []}"#)
        XCTAssertNil(list.backend)
        XCTAssertTrue(list.models.isEmpty)
        XCTAssertEqual(list.error, "add an API key for OpenAI first (`huske llm key set openai`)")
    }

    // MARK: test

    func testSuccessfulTestDecodes() throws {
        let result = try LLMBridge.parseTest("""
            {"ok": true, "label": "apple:apple-on-device",
             "input": ["good morning everyone", "sounds good"],
             "output": ["Good morning, everyone.", "Sounds good."],
             "changed": 2, "kept_raw": 0, "seconds": 1.6, "error": null}
            """)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.label, "apple:apple-on-device")
        XCTAssertEqual(result.changed, 2)
        XCTAssertEqual(result.keptRaw, 0)
        XCTAssertEqual(result.seconds, 1.6)
        XCTAssertEqual(result.pairs.count, 2)
        XCTAssertEqual(result.pairs[0].before, "good morning everyone")
        XCTAssertEqual(result.pairs[0].after, "Good morning, everyone.")
    }

    func testFailedTestDecodes() throws {
        let result = try LLMBridge.parseTest(
            #"{"error": "no OpenAI API key in the Keychain; add one in Huske.app or with `huske llm key set openai`", "ok": false, "kind": "auth"}"#)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.kind, "auth")
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertNil(result.seconds)
        XCTAssertEqual(result.error?.hasPrefix("no OpenAI API key"), true)
    }

    func testTestWithoutOkFollowsTheError() throws {
        XCTAssertFalse(try LLMBridge.parseTest(#"{"error": "boom"}"#).ok)
        XCTAssertTrue(try LLMBridge.parseTest(#"{"input": [], "output": []}"#).ok)
    }

    // MARK: keys + consent

    func testKeyResultsDecode() throws {
        let saved = try LLMBridge.parseKeyResult(
            #"{"provider": "openai", "saved": true, "error": null}"#, field: "saved")
        XCTAssertEqual(saved, LLMKeyResult(provider: "openai", done: true, error: nil))
        let refused = try LLMBridge.parseKeyResult(
            #"{"error": "that doesn't look like an API key (expected one line of letters, digits and - _ . characters)", "saved": false}"#,
            field: "saved")
        XCTAssertFalse(refused.done)
        XCTAssertNil(refused.provider)
        XCTAssertEqual(refused.error?.hasPrefix("that doesn't look like an API key"), true)
        let removed = try LLMBridge.parseKeyResult(
            #"{"provider": "openai", "removed": false, "error": null}"#, field: "removed")
        XCTAssertFalse(removed.done)
        XCTAssertEqual(removed.provider, "openai")
    }

    func testKeyListDecodes() throws {
        let keys = try LLMBridge.parseKeyList(
            #"{"keys": {"openai_compatible": false, "openai": true, "anthropic": false, "openrouter": false}}"#)
        XCTAssertEqual(keys["openai"], true)
        XCTAssertEqual(keys.count, 4)
        XCTAssertTrue(try LLMBridge.parseKeyList("{}").isEmpty)
    }

    func testConsentDecodes() throws {
        XCTAssertEqual(
            try LLMBridge.parseConsent(#"{"consent": "api.openai.com", "error": null}"#),
            LLMConsentResult(consent: "api.openai.com", error: nil))
        XCTAssertEqual(
            try LLMBridge.parseConsent(#"{"consent": null, "error": null}"#),
            LLMConsentResult(consent: nil, error: nil))
        XCTAssertEqual(
            try LLMBridge.parseConsent(#"{"error": "nothing to allow: built-in model runs on this Mac"}"#).error,
            "nothing to allow: built-in model runs on this Mac")
    }

    // MARK: languages

    func testLanguagesDecode() throws {
        let languages = try LLMBridge.parseLanguages("""
            {"languages": [
              {"code": "en", "name": "English", "whisper": "pinned", "parakeet": "detected"},
              {"code": "ja", "name": "Japanese", "whisper": "pinned", "parakeet": "unsupported"},
              {"code": "pt", "name": "Portuguese"},
              {"name": "no code"}]}
            """)
        XCTAssertEqual(languages.map(\.code), ["en", "ja", "pt"])
        XCTAssertTrue(languages[0].parakeetSupported)
        XCTAssertFalse(languages[1].parakeetSupported)
        // Missing support fields fall back to the built-in Parakeet list.
        XCTAssertEqual(languages[2].whisper, "pinned")
        XCTAssertTrue(languages[2].parakeetSupported)
        XCTAssertEqual(LanguageInfo.parakeetCodes.count, 25)
    }

    // MARK: running the CLI

    func testStdinReachesTheChildAndIsClosed() async throws {
        let result = try await CLIRunner.run(
            binary: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            stdin: Data("line one\nline two\n".utf8), timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "line one\nline two\n")
    }

    func testWithoutStdinTheChildReadsNothing() async throws {
        let result = try await CLIRunner.run(
            binary: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 10)
        XCTAssertEqual(result.stdout, "")
    }

    func testAChildThatNeverReadsStdinDoesNotTakeTheAppDown() async throws {
        let result = try await CLIRunner.run(
            binary: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            stdin: Data(repeating: 0x41, count: 4096), timeout: 10)
        XCTAssertEqual(result.status, 0)
    }

    /// The key travels on stdin, never in argv, and the answer is decoded.
    func testSaveKeySendsTheKeyOnStdinOnly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-llm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("huske")
        try """
            #!/bin/sh
            read -r key
            case "$*" in *sk-test*) echo '{"saved": false, "error": "key in argv"}'; exit 2;; esac
            if [ "$key" = "sk-test-0123456789" ] && [ "$*" = "llm key set openai --json" ]; then
              echo '{"provider": "openai", "saved": true, "error": null}'
            else
              echo '{"saved": false, "error": "mismatch"}'; exit 2
            fi
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let result = try await LLMBridge.saveKey(
            binary: fake, provider: "openai", key: "sk-test-0123456789")
        XCTAssertEqual(result, LLMKeyResult(provider: "openai", done: true, error: nil))
    }

    func testAFailedCommandWithoutJSONSaysWhatItPrinted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-llm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("huske")
        try "#!/bin/sh\necho 'No such command: llm' >&2\nexit 2\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        do {
            _ = try await LLMBridge.status(binary: fake)
            XCTFail("expected badOutput")
        } catch LLMBridgeError.badOutput(let said) {
            XCTAssertEqual(said, "No such command: llm")
        }
    }
}

/// The words the Configuration pane and the transcript header derive from
/// engine data.
final class CleanupWordsTests: XCTestCase {
    func testProvenanceNamesWhereCleanupRan() {
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "apple:apple-on-device"), "Apple Intelligence")
        XCTAssertEqual(
            CleanupWords.provenance(postprocessedBy: "mlx:mlx-community/Qwen3.5-0.8B-4bit"),
            "the built-in model")
        // Ollama tags carry their own colon; only the first one splits.
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "ollama:qwen3.5:0.8b"), "Ollama")
        XCTAssertEqual(
            CleanupWords.provenance(postprocessedBy: "openai_compatible:default"), "a local server")
        XCTAssertEqual(
            CleanupWords.provenance(postprocessedBy: "anthropic:claude-haiku-5-5"),
            "Anthropic · claude-haiku-5-5")
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "openai:gpt-5-mini"), "OpenAI · gpt-5-mini")
        XCTAssertEqual(
            CleanupWords.provenance(postprocessedBy: "openrouter:meta-llama/llama-4:free"),
            "OpenRouter · meta-llama/llama-4:free")
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "openai:default"), "OpenAI")
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "openai"), "OpenAI")
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "heuristic:fake"), "heuristic")
        XCTAssertEqual(CleanupWords.provenance(postprocessedBy: "  "), "")
    }

    func testLanguageNoteFollowsTheEngine() {
        let languages = [
            LanguageInfo(code: "pt", name: "Portuguese", parakeet: "detected"),
            LanguageInfo(code: "ja", name: "Japanese", parakeet: "unsupported"),
        ]
        XCTAssertEqual(
            CleanupWords.languageNote(engine: "whisper", code: "pt", languages: languages),
            "Whisper transcribes in this language only.")
        XCTAssertTrue(
            CleanupWords.languageNote(engine: "whisper", code: "", languages: languages)
                .hasPrefix("Whisper works out the language"))
        let parakeetPT = CleanupWords.languageNote(engine: "parakeet", code: "pt", languages: languages)
        XCTAssertTrue(parakeetPT.hasPrefix("Parakeet can't be told the language"))
        XCTAssertTrue(parakeetPT.contains("slip into English and redo them"))
        XCTAssertTrue(parakeetPT.hasSuffix("switch to Whisper (large-v3-turbo)."))
        XCTAssertEqual(
            CleanupWords.languageNote(engine: "parakeet", code: "ja", languages: languages),
            "Parakeet doesn't understand Japanese. To transcribe it, switch to Whisper (large-v3-turbo).")
        XCTAssertFalse(
            CleanupWords.languageNote(engine: "parakeet", code: "en", languages: languages)
                .contains("slip into English"))
        XCTAssertTrue(
            CleanupWords.languageNote(engine: "parakeet", code: "", languages: [])
                .hasPrefix("Parakeet works out the language as it goes."))
    }

    func testLanguageNoteWithoutTheEnginesListUsesParakeetsOwn() {
        XCTAssertTrue(
            CleanupWords.languageNote(engine: "parakeet", code: "de", languages: [])
                .hasPrefix("Parakeet can't be told"))
        XCTAssertEqual(
            CleanupWords.languageNote(engine: "parakeet", code: "ko", languages: []),
            "Parakeet doesn't understand Korean. To transcribe it, switch to Whisper (large-v3-turbo).")
    }

    func testVocabularyLinesAreTrimmedDedupedAndKeepTheirOrder() {
        XCTAssertEqual(
            CleanupWords.vocabulary(fromLines: "  Kubernetes \n\nOKR\r\nHuske\nOKR\n   \n"),
            ["Kubernetes", "OKR", "Huske"])
        XCTAssertEqual(CleanupWords.vocabulary(fromLines: "\n \n"), [])
    }

    func testReplacementRowsSkipHalfTypedOnes() {
        XCTAssertEqual(
            CleanupWords.replacements(fromRows: [
                (" cube ernetes ", "Kubernetes "), ("okay are", ""), ("", "OKR"), ("dash board", "dashboard"),
            ]),
            ["cube ernetes": "Kubernetes", "dash board": "dashboard"])
    }

    func testSecondsAndSentences() {
        XCTAssertEqual(CleanupWords.seconds(1.62), "1.6s")
        XCTAssertEqual(CleanupWords.seconds(12.4), "12s")
        XCTAssertEqual(
            CleanupWords.sentence("no OpenAI API key in the Keychain"), "No OpenAI API key in the Keychain")
        XCTAssertEqual(CleanupWords.sentence("Already fine"), "Already fine")
        XCTAssertEqual(CleanupWords.sentence(""), "")
    }
}
