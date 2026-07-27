import XCTest

@testable import HuskeKit

/// End-to-end line-protocol test against an in-process AF_UNIX server that
/// behaves like huske's ControlServer (replays a snapshot on accept, receives
/// command lines).
final class LineSocketClientTests: XCTestCase {
    private var serverFD: Int32 = -1
    private var socketPath = ""

    override func setUpWithError() throws {
        // Keep the path short — AF_UNIX allows ~104 bytes.
        socketPath = "/tmp/hsk-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
        unlink(socketPath)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(serverFD, sa, size)
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(serverFD, 2), 0)
    }

    override func tearDownWithError() throws {
        if serverFD >= 0 { close(serverFD) }
        unlink(socketPath)
    }

    func testReceivesSnapshotAndSendsCommand() throws {
        let snapshotLine = """
            {"type":"state","session_id":"s","recording":true,"paused":false,\
            "stopping":false,"current_chunk_seq":1,"queue_depth":0,\
            "screenshots_enabled":false,"distill_enabled":false,"last_saved_name":null}\n
            """
        let received = expectation(description: "snapshot received")
        let commandRead = expectation(description: "command read by server")

        let fd = serverFD
        // Server side: accept, replay one snapshot, then read one command line.
        DispatchQueue.global().async {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            _ = snapshotLine.withCString { cstr in
                write(conn, cstr, strlen(cstr))
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var line = Data()
            while !line.contains(0x0A) {
                let n = read(conn, &buffer, buffer.count)
                if n <= 0 { break }
                line.append(contentsOf: buffer[0..<n])
            }
            if let text = String(data: line, encoding: .utf8),
               text.contains("\"name\":\"pause_resume\"")
            {
                commandRead.fulfill()
            }
            close(conn)
        }

        let client = LineSocketClient(path: socketPath)
        client.onMessage = { message in
            if case .state(let snap) = message, snap.recording {
                received.fulfill()
            }
        }
        try client.connect()
        wait(for: [received], timeout: 3.0)

        client.send(.pauseResume)
        wait(for: [commandRead], timeout: 3.0)
        client.close()
    }

    func testDisconnectFiresOnServerClose() throws {
        let disconnected = expectation(description: "disconnect fired")
        let fd = serverFD
        DispatchQueue.global().async {
            let conn = accept(fd, nil, nil)
            if conn >= 0 {
                usleep(100_000)
                close(conn)
            }
        }
        let client = LineSocketClient(path: socketPath)
        client.onDisconnect = { disconnected.fulfill() }
        try client.connect()
        wait(for: [disconnected], timeout: 3.0)
    }

    func testConnectToMissingSocketThrows() {
        let client = LineSocketClient(path: "/tmp/hsk-definitely-missing.sock")
        XCTAssertThrowsError(try client.connect())
    }
}

final class MeterTests: XCTestCase {
    func testNormalizeMapsTUIScale() {
        XCTAssertEqual(MeterScale.normalize(db: -120), 0)
        XCTAssertEqual(MeterScale.normalize(db: -60), 0)
        XCTAssertEqual(MeterScale.normalize(db: -30), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MeterScale.normalize(db: 0), 1)
        XCTAssertEqual(MeterScale.normalize(db: 10), 1)
    }

    func testZones() {
        XCTAssertEqual(MeterScale.zone(db: -30), .quiet)
        XCTAssertEqual(MeterScale.zone(db: -10), .loud)
        XCTAssertEqual(MeterScale.zone(db: -3), .hot)
    }

    func testAttackIsFasterThanRelease() {
        var meter = SmoothedMeter()
        let t0 = Date(timeIntervalSince1970: 1000)
        meter.step(targetDb: -60, now: t0)
        XCTAssertEqual(meter.level, 0, accuracy: 0.001)

        // Rise toward -6 dB (0.9 normalized) over 100 ms.
        meter.step(targetDb: -6, now: t0.addingTimeInterval(0.1))
        let risen = meter.level
        XCTAssertGreaterThan(risen, 0.5)

        // Drop back to silence for 100 ms — should fall much more slowly.
        meter.step(targetDb: -120, now: t0.addingTimeInterval(0.2))
        XCTAssertGreaterThan(meter.level, risen * 0.5)
    }

    func testPeakHoldsThenDecays() {
        var meter = SmoothedMeter()
        var now = Date(timeIntervalSince1970: 1000)
        meter.step(targetDb: -6, now: now)
        for _ in 0..<20 {
            now = now.addingTimeInterval(0.125)
            meter.step(targetDb: -6, now: now)
        }
        let peakWhileLoud = meter.peak
        XCTAssertGreaterThan(peakWhileLoud, 0.85)

        // Go quiet: peak holds for ~1.2 s, then decays below its held value.
        for _ in 0..<4 {
            now = now.addingTimeInterval(0.125)
            meter.step(targetDb: -120, now: now)
        }
        XCTAssertEqual(meter.peak, peakWhileLoud, accuracy: 0.001)
        for _ in 0..<24 {
            now = now.addingTimeInterval(0.125)
            meter.step(targetDb: -120, now: now)
        }
        XCTAssertLessThan(meter.peak, peakWhileLoud)
    }
}

final class BinaryLocatorTests: XCTestCase {
    func testExplicitOverrideWins() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hsk-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("huske")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertEqual(BinaryLocator.locate(override: fake.path), fake)
    }

    func testBrokenOverrideDoesNotFallBack() {
        XCTAssertNil(
            BinaryLocator.locate(
                override: "/tmp/definitely-not-huske-\(UUID().uuidString)",
                environment: ["PATH": "/usr/bin:/bin"]
            ))
    }

    func testFindsBinaryOnPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hsk-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("huske")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let found = BinaryLocator.locate(environment: ["PATH": dir.path])
        // Well-known locations shadow PATH; only assert when none exists here.
        if BinaryLocator.wellKnownPaths.allSatisfy({
            !FileManager.default.isExecutableFile(atPath: ($0 as NSString).expandingTildeInPath)
        }) {
            XCTAssertEqual(found, fake)
        }
    }
}

final class BridgeParsingTests: XCTestCase {
    func testParsesConfigShowJSON() throws {
        let json = """
            {"path": "/Users/me/.config/huske/config.toml", "exists": true,
             "file": {"chunk_minutes": 5.0, "input_device": "MacBook Pro Microphone"},
             "effective": {"chunk_minutes": 5.0, "speech_gated": true,
                           "asr_engine": "parakeet", "silence_split_seconds": 60.0,
                           "input_device": "MacBook Pro Microphone",
                           "output_root": "/Users/me/huske/transcripts"}}
            """
        let snapshot = try ConfigBridge.parseShowJSON(json)
        XCTAssertTrue(snapshot.exists)
        XCTAssertEqual(snapshot.explicitKeys, ["chunk_minutes", "input_device"])
        XCTAssertEqual(snapshot.double("chunk_minutes"), 5.0)
        XCTAssertEqual(snapshot.bool("speech_gated"), true)
        XCTAssertEqual(snapshot.string("asr_engine"), "parakeet")
        XCTAssertEqual(snapshot.string("output_root"), "/Users/me/huske/transcripts")
        XCTAssertNil(snapshot.string("chunk_minutes")) // wrong type accessor → nil
    }

    func testParsesDoctorJSON() throws {
        let json = """
            {"version": "0.11.0", "ok": false,
             "checks": [
               {"name": "Python", "ok": true, "detail": "3.13.2", "hint": null},
               {"name": "microphone", "ok": false, "detail": "no input device found",
                "hint": "Connect a microphone (built-in or USB) and re-run."}],
             "input_devices": [
               {"index": 1, "name": "MacBook Pro Microphone", "channels": 1,
                "sample_rate": 48000.0}]}
            """
        let report = try DoctorBridge.parse(json)
        XCTAssertEqual(report.version, "0.11.0")
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.checks.count, 2)
        XCTAssertEqual(report.checks[1].name, "microphone")
        XCTAssertNotNil(report.checks[1].hint)
        XCTAssertEqual(report.inputDevices.first?.name, "MacBook Pro Microphone")
    }
}
