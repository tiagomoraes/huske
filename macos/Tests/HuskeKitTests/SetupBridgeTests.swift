import XCTest

@testable import HuskeKit

/// Decoding `huske setup --json`. The contract is defined in `huske/setup.py`;
/// `PythonInteropTests` drives the real engine, so these cover the parsing edges
/// that a fixture can express and a live run cannot easily produce.
final class SetupBridgeTests: XCTestCase {
    private let fullReport = """
        {
          "ready": false,
          "endpoint": "http://127.0.0.1:7641/mcp",
          "connector_url": null,
          "steps": [
            {"key": "extra", "title": "Search engine installed", "state": "ok",
             "detail": "huske[mcp] is present", "fix": null, "can_apply": false},
            {"key": "index", "title": "Transcripts indexed", "state": "todo",
             "detail": "0 of 4 transcript(s) indexed", "fix": "huske index",
             "can_apply": true},
            {"key": "server", "title": "Search server running", "state": "todo",
             "detail": "Start it so clients can reach the index.", "fix": "huske mcp",
             "can_apply": false},
            {"key": "claude-desktop", "title": "Claude Desktop", "state": "ok",
             "detail": "installed", "fix": null, "can_apply": true},
            {"key": "connector", "title": "Reachable from other devices",
             "state": "optional", "detail": "Off. Needs a server you control.",
             "fix": null, "can_apply": false}
          ]
        }
        """

    func testParsesEveryField() throws {
        let report = try SetupBridge.parse(fullReport)
        XCTAssertFalse(report.ready)
        XCTAssertEqual(report.endpoint, "http://127.0.0.1:7641/mcp")
        XCTAssertNil(report.connectorURL)
        XCTAssertEqual(report.steps.count, 5)

        let index = try XCTUnwrap(report.step("index"))
        XCTAssertEqual(index.state, .todo)
        XCTAssertEqual(index.fix, "huske index")
        XCTAssertTrue(index.canApply)

        let extra = try XCTUnwrap(report.step("extra"))
        XCTAssertEqual(extra.state, .ok)
        XCTAssertNil(extra.fix)
    }

    func testActionableIsOnlyWhatNeedsDoing() throws {
        let report = try SetupBridge.parse(fullReport)
        XCTAssertEqual(report.actionable.map(\.key), ["index", "server"])
    }

    /// A newer engine adding a state must not make an older app render a broken
    /// row — unknown states degrade to `optional` (inert, no button).
    func testUnknownStateDegradesToOptional() throws {
        let report = try SetupBridge.parse(
            """
            {"ready": false, "endpoint": "", "connector_url": null,
             "steps": [{"key": "future", "title": "Something new",
                        "state": "quantum", "detail": "", "fix": null,
                        "can_apply": false}]}
            """)
        XCTAssertEqual(report.step("future")?.state, .optional)
        XCTAssertTrue(report.actionable.isEmpty)
    }

    func testConnectorURLIsCarriedWhenSet() throws {
        let report = try SetupBridge.parse(
            """
            {"ready": true, "endpoint": "http://127.0.0.1:7641/mcp",
             "connector_url": "https://huske.example.com/mcp", "steps": []}
            """)
        XCTAssertEqual(report.connectorURL, "https://huske.example.com/mcp")
        XCTAssertTrue(report.ready)
    }

    func testMissingOptionalFieldsDefaultSafely() throws {
        let report = try SetupBridge.parse(
            """
            {"steps": [{"key": "index", "title": "Transcripts indexed"}]}
            """)
        let step = try XCTUnwrap(report.step("index"))
        XCTAssertEqual(step.detail, "")
        XCTAssertNil(step.fix)
        XCTAssertFalse(step.canApply)
        XCTAssertFalse(report.ready)
    }

    func testStepsWithoutAKeyAreDropped() throws {
        let report = try SetupBridge.parse(
            """
            {"steps": [{"title": "no key here"},
                       {"key": "index", "title": "Transcripts indexed"}]}
            """)
        XCTAssertEqual(report.steps.map(\.key), ["index"])
    }

    func testNonJSONThrows() {
        XCTAssertThrowsError(try SetupBridge.parse("huske setup\n  ✓ ready\n")) { error in
            XCTAssertEqual(error as? SetupBridgeError, .badOutput)
        }
    }

    func testJSONWithoutStepsThrows() {
        XCTAssertThrowsError(try SetupBridge.parse(#"{"ready": true}"#)) { error in
            XCTAssertEqual(error as? SetupBridgeError, .badOutput)
        }
    }
}

@MainActor
final class SearchServerControllerTests: XCTestCase {
    func testStartsStopped() {
        let controller = SearchServerController()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.failure)
    }

    /// A server started from a terminal or LaunchAgent must be adopted, not
    /// duplicated — the pane should offer Stop, not a second Start.
    func testAdoptExternalMarksRunning() {
        let controller = SearchServerController()
        controller.adoptExternal()
        XCTAssertTrue(controller.isRunning)
    }

    /// Stopping something we never spawned must not claim to have killed it.
    func testStopWithoutOwnedProcessIsInert() {
        let controller = SearchServerController()
        controller.adoptExternal()
        controller.stop()
        XCTAssertEqual(controller.state, .stopped)
    }
}
