import XCTest

@testable import HuskeKit

/// The environment every engine child process gets — `huske run` and the
/// one-shot CLI calls alike — and finding the helper inside Huske.app.
final class HelperLocatorTests: XCTestCase {
    private let helper = URL(fileURLWithPath: "/Applications/Huske.app/Contents/Helpers/huske-apple-llm")

    func testHelperIsInjectedWhenTheEnvironmentNamesNone() {
        let env = HelperLocator.childEnvironment(base: ["PATH": "/usr/bin"], helper: helper)
        XCTAssertEqual(env["HUSKE_APPLE_LLM_HELPER"], helper.path)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HUSKE_NO_UPDATE_CHECK"], "1")
    }

    func testAnExistingChoiceIsKept() {
        let env = HelperLocator.childEnvironment(
            base: ["HUSKE_APPLE_LLM_HELPER": "/opt/dev/huske-apple-llm"], helper: helper)
        XCTAssertEqual(env["HUSKE_APPLE_LLM_HELPER"], "/opt/dev/huske-apple-llm")
    }

    func testAnEmptyChoiceCountsAsNone() {
        let env = HelperLocator.childEnvironment(
            base: ["HUSKE_APPLE_LLM_HELPER": ""], helper: helper)
        XCTAssertEqual(env["HUSKE_APPLE_LLM_HELPER"], helper.path)
    }

    func testNoBundledHelperAddsNothing() {
        let env = HelperLocator.childEnvironment(base: [:], helper: nil)
        XCTAssertNil(env["HUSKE_APPLE_LLM_HELPER"])
        XCTAssertEqual(env["HUSKE_NO_UPDATE_CHECK"], "1")
    }

    func testOverridesWinOverEverything() {
        let env = HelperLocator.childEnvironment(
            base: ["HUSKE_NO_UPDATE_CHECK": "0", "A": "base"], helper: helper,
            overrides: ["A": "override", "HUSKE_APPLE_LLM_HELPER": "/x"])
        XCTAssertEqual(env["A"], "override")
        XCTAssertEqual(env["HUSKE_APPLE_LLM_HELPER"], "/x")
        XCTAssertEqual(env["HUSKE_NO_UPDATE_CHECK"], "1")
    }

    func testHelperIsFoundInsideABundle() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-\(UUID().uuidString).app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }

        XCTAssertNil(HelperLocator.appleLLMHelper(inBundle: app), "nothing there yet")
        let binary = helpers.appendingPathComponent("huske-apple-llm")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        XCTAssertNil(HelperLocator.appleLLMHelper(inBundle: app), "present but not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(
            HelperLocator.appleLLMHelper(inBundle: app)?.resolvingSymlinksInPath().path,
            binary.resolvingSymlinksInPath().path)
    }

    func testTheProbeLooksAtContentsHelpers() {
        var asked: [String] = []
        _ = HelperLocator.appleLLMHelper(inBundle: URL(fileURLWithPath: "/Applications/Huske.app")) {
            asked.append($0)
            return false
        }
        XCTAssertEqual(asked, ["/Applications/Huske.app/Contents/Helpers/huske-apple-llm"])
    }
}

/// `huske config set KEY VALUE` literals and list/table accessors.
final class ConfigLiteralTests: XCTestCase {
    func testStringsAreAlwaysJSONQuoted() {
        XCTAssertEqual(ConfigLiteral.encode(.string("parakeet")), #""parakeet""#)
        // Free text must not turn into a bool, number or null on the way in.
        XCTAssertEqual(ConfigLiteral.encode(.string("true")), #""true""#)
        XCTAssertEqual(ConfigLiteral.encode(.string("123")), #""123""#)
        XCTAssertEqual(ConfigLiteral.encode(.string("null")), #""null""#)
        XCTAssertEqual(
            ConfigLiteral.encode(.string("Remove filler words.\nKeep names.")),
            #""Remove filler words.\nKeep names.""#)
        XCTAssertEqual(ConfigLiteral.encode(.string("~/huske/transcripts")), #""~/huske/transcripts""#)
    }

    func testListsAndTablesAreJSON() throws {
        let list = try XCTUnwrap(
            ConfigLiteral.encode(.array([.string("Kubernetes"), .string("OKR"), .string("Ana Lúcia")])))
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String],
            ["Kubernetes", "OKR", "Ana Lúcia"])
        XCTAssertEqual(
            ConfigLiteral.encode(.object(["okay are": .string("OKR"), "cube ernetes": .string("Kubernetes")])),
            #"{"cube ernetes":"Kubernetes","okay are":"OKR"}"#)
        XCTAssertEqual(ConfigLiteral.encode(.array([])), "[]")
    }

    func testScalarsKeepTheirSpelling() {
        XCTAssertEqual(ConfigLiteral.encode(.bool(true)), "true")
        XCTAssertEqual(ConfigLiteral.encode(.number(15)), "15.0")
        XCTAssertEqual(ConfigLiteral.encode(.number(0.5)), "0.5")
        XCTAssertNil(ConfigLiteral.encode(.null))
    }

    func testSnapshotListAndTableAccessors() throws {
        let snapshot = try ConfigBridge.parseShowJSON("""
            {"path": "/tmp/c.toml", "exists": true, "file": {"vocabulary": []},
             "effective": {"vocabulary": ["Kubernetes", 3, "OKR"],
                           "vocabulary_replacements": {"cube ernetes": "Kubernetes", "bad": 1},
                           "language": null}}
            """)
        XCTAssertEqual(snapshot.stringList("vocabulary"), ["Kubernetes", "OKR"])
        XCTAssertEqual(snapshot.stringMap("vocabulary_replacements"), ["cube ernetes": "Kubernetes"])
        XCTAssertNil(snapshot.stringList("vocabulary_replacements"))
        XCTAssertNil(snapshot.stringMap("missing"))
        XCTAssertNil(snapshot.string("language"))
    }
}
