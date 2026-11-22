import XCTest

@testable import HuskeKit

final class EngineCapabilitiesTests: XCTestCase {
    func testModernEngineParses() {
        let caps = EngineCapabilities.parse(
            versionOutput: "huske 0.11.0\n",
            runHelp: "Options:\n  --control-socket PATH  Serve the control protocol…\n",
            mainHelp: """
                ╭─ Commands ───────────────╮
                │ run       Start a session │
                │ config    Inspect config  │
                │ devices   List inputs     │
                ╰──────────────────────────╯
                """
        )
        XCTAssertEqual(caps.version, "0.11.0")
        XCTAssertTrue(caps.controlSocket)
        XCTAssertTrue(caps.configCLI)
        XCTAssertTrue(caps.devicesCLI)
        XCTAssertTrue(caps.isCurrent)
    }

    func testLegacyEngineParses() {
        let caps = EngineCapabilities.parse(
            versionOutput: "huske 0.10.0",
            runHelp: "Options:\n  --chunk-minutes\n  --menu-bar/--no-menu-bar\n",
            mainHelp: """
                Commands:
                  run      Start a recording session
                  recover  Process orphaned audio
                  doctor   Validate audio devices ("configured microphone" text)
                """
        )
        XCTAssertEqual(caps.version, "0.10.0")
        XCTAssertFalse(caps.controlSocket)
        XCTAssertFalse(caps.configCLI)
        XCTAssertFalse(caps.devicesCLI)
        XCTAssertFalse(caps.isCurrent)
    }

    func testCommandMatchIsWordAnchored() {
        // "configured" or "device settings" prose must not count.
        let caps = EngineCapabilities.parse(
            versionOutput: "",
            runHelp: "",
            mainHelp: "doctor   Checks the configured microphone and devices attached"
        )
        XCTAssertFalse(caps.configCLI)
        XCTAssertFalse(caps.devicesCLI)
    }

    func testSanitizeStripsTyperBoxes() {
        let raw = [
            "Usage: huske run [OPTIONS]",
            "╭─ Error ─────────────────────────╮",
            "│ No such option: --control-socket │",
            "╰─────────────────────────────────╯",
        ]
        let cleaned = EngineOutput.sanitize(raw)
        XCTAssertEqual(
            cleaned,
            "Usage: huske run [OPTIONS]\nNo such option: --control-socket")
    }

    func testCleanupAndLanguagesCommandsAreDetected() {
        let caps = EngineCapabilities.parse(
            versionOutput: "huske 0.15.0",
            runHelp: "--control-socket",
            mainHelp: """
                ╭─ Commands ───────────────────────────────────────────╮
                │ run        Start a headless recording session        │
                │ devices    List microphone input devices             │
                │ languages  Language codes for `language`, and what   │
                │            each engine does with them.               │
                │ config     Inspect and edit the huske config file    │
                │ llm        Set up transcript cleanup with a language │
                │            model: Apple Intelligence, a local model, │
                ╰──────────────────────────────────────────────────────╯
                """
        )
        XCTAssertTrue(caps.llmCLI)
        XCTAssertTrue(caps.languagesCLI)
    }

    func testEnginesBeforeCleanupLackIt() {
        let caps = EngineCapabilities.parse(
            versionOutput: "huske 0.14.0",
            runHelp: "--control-socket",
            mainHelp: """
                │ run       Start a session                                   │
                │ distill   Correct ASR errors in transcripts with a tiny llm │
                │ config    Inspect config                                    │
                """
        )
        XCTAssertFalse(caps.llmCLI, "'llm' inside a description is not the command")
        XCTAssertFalse(caps.languagesCLI)
        XCTAssertTrue(caps.configCLI)
        XCTAssertFalse(caps.modelsCLI)
    }

    func testModelsCommandIsDetected() {
        // The engine's real `--help` rows.
        let caps = EngineCapabilities.parse(
            versionOutput: "huske 0.15.0",
            runHelp: "--control-socket",
            mainHelp: """
                │ languages  Language codes for `language`, and what each engine does with     │
                │ llm        Set up transcript cleanup with a language model: Apple            │
                │ models     See, choose, download and try transcription models. Without a     │
                """
        )
        XCTAssertTrue(caps.modelsCLI)
        let older = EngineCapabilities.parse(
            versionOutput: "huske 0.14.0",
            runHelp: "--control-socket",
            mainHelp: """
                │ llm        Set up transcript cleanup with a language model: Apple            │
                │            models, a local server, or a cloud provider.                       │
                """
        )
        XCTAssertFalse(older.modelsCLI, "'models' wrapped inside a description is not the command")
    }
}
