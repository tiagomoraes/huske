import XCTest

@testable import HuskeKit

/// Cross-language contract test: drives the *real* Python ControlServer
/// (huske/ipc/server.py) with the Swift client. Gated on the
/// HUSKE_INTEROP_PYTHON environment variable (path to a python with huske
/// importable) so plain `swift test` stays hermetic:
///
///   HUSKE_INTEROP_PYTHON=../.venv/bin/python swift test --filter PythonInterop
final class PythonInteropTests: XCTestCase {
    private static let serverScript = """
        import sys, time
        from pathlib import Path
        from huske.control import Command, CommandChannel
        from huske.ipc.protocol import ControlSnapshot
        from huske.ipc.server import ControlServer

        sock = Path(sys.argv[1])
        channel = CommandChannel()
        server = ControlServer(sock, channel)
        server.start()
        snap = ControlSnapshot(
            session_id="interop", recording=True, paused=False, stopping=False,
            current_chunk_seq=7, queue_depth=1, screenshots_enabled=False,
            distill_enabled=False, last_saved_name=None,
            peak_mic_db=-25.0, peak_system_db=-40.0,
            chunk_started_at="2026-07-21T09:00:00.123456-03:00",
            session_started_at="2026-07-21T08:59:00-03:00",
            huske_version="interop", output_root="/tmp",
            input_device_name="Interop Mic",
            warnings={"heartbeat": "test warning"},
            events=[{"ts": "2026-07-21T09:00:01-03:00", "severity": "info",
                     "message": "hello from python"}],
        )
        got = None
        deadline = time.time() + 20
        while time.time() < deadline and got is None:
            server.broadcast_state(snap)
            for cmd, arg in channel.drain():
                got = (cmd, arg)
            time.sleep(0.05)
        server.stop()
        ok = got == (Command.SET_INPUT_DEVICE, "Interop Mic 2")
        print("RESULT", "ok" if ok else got, flush=True)
        sys.exit(0 if ok else 1)
        """

    func testSwiftClientAgainstRealPythonServer() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let socketPath = "/tmp/hsk-interop-\(UInt32.random(in: 0..<UInt32.max)).sock"
        defer { unlink(socketPath) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = ["-c", Self.serverScript, socketPath]
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer { if server.isRunning { server.terminate() } }

        // Poll-connect while the server binds its socket.
        let client = LineSocketClient(path: socketPath)
        let snapshotReceived = expectation(description: "v2 snapshot decoded")
        nonisolated(unsafe) var receivedOnce = false
        client.onMessage = { message in
            guard case .state(let snap) = message, !receivedOnce else { return }
            receivedOnce = true
            XCTAssertEqual(snap.sessionId, "interop")
            XCTAssertEqual(snap.currentChunkSeq, 7)
            XCTAssertEqual(snap.peakMicDb, -25.0, accuracy: 0.001)
            XCTAssertEqual(snap.inputDeviceName, "Interop Mic")
            XCTAssertEqual(snap.warnings["heartbeat"], "test warning")
            XCTAssertEqual(snap.events.first?.message, "hello from python")
            XCTAssertNotNil(snap.chunkStartedAt) // microsecond fraction parses
            snapshotReceived.fulfill()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? client.connect()) != nil { break }
            usleep(100_000)
        }
        XCTAssertTrue(client.isConnected, "could not connect to the python server")

        wait(for: [snapshotReceived], timeout: 10)

        // Command with an argument must arrive typed on the Python side.
        client.send(.setInputDevice, arg: "Interop Mic 2")
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0, "python server did not receive the command")
        client.close()
    }

    /// The other cross-language contract: `huske setup --json` is what the
    /// Connect pane renders, so a renamed key or state would silently blank a
    /// row rather than fail a build. Runs the real CLI and decodes it with the
    /// real bridge.
    func testSetupJSONDecodesWithTheSwiftBridge() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-setup-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "huske", "setup", "--json", "--config", "/nonexistent.toml"]
        var env = ProcessInfo.processInfo.environment
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        // Isolate from the developer's real ~/.config/huske and ~/huske.
        env["HOME"] = home.path
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        let report = try SetupBridge.parse(text)

        // Every key the pane switches on must be present, or its row vanishes.
        for key in ["extra", "index", "server", "connector"] {
            XCTAssertNotNil(report.step(key), "setup --json is missing the '\(key)' step")
        }
        XCTAssertTrue(report.endpoint.hasSuffix("/mcp"), "unexpected endpoint: \(report.endpoint)")
        // Nothing is set up in a throwaway HOME, so this must not claim ready.
        XCTAssertFalse(report.ready)
    }
}
