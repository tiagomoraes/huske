import XCTest

@testable import HuskeKit

final class ControlProtocolTests: XCTestCase {
    // A verbatim v2 line as huske/ipc/protocol.py emits it.
    private let v2Line = """
        {"type":"state","session_id":"20260509T120000_abcd","recording":true,\
        "paused":false,"stopping":false,"current_chunk_seq":2,"queue_depth":1,\
        "screenshots_enabled":false,"distill_enabled":true,\
        "last_saved_name":"120015_abcd0000_001.md","peak_mic_db":-23.5,\
        "peak_system_db":-41.0,"chunk_started_at":"2026-05-09T12:00:00.123456-03:00",\
        "next_rotation_at":"2026-05-09T12:30:00-03:00",\
        "session_started_at":"2026-05-09T11:59:00-03:00","huske_version":"0.11.0",\
        "output_root":"/Users/me/huske/transcripts",\
        "last_saved_path":"/Users/me/huske/transcripts/2026-05-09/120015_abcd0000_001.md",\
        "screenshots_count":4,"input_device_name":"MacBook Pro Microphone",\
        "warnings":{"heartbeat":"no audio for 6s"},\
        "events":[{"ts":"2026-05-09T12:00:01-03:00","severity":"info","message":"hi"}]}
        """

    func testDecodesV2Snapshot() throws {
        let message = try ControlProtocol.decode(line: v2Line)
        guard case .state(let snap) = message else {
            return XCTFail("expected state message")
        }
        XCTAssertEqual(snap.sessionId, "20260509T120000_abcd")
        XCTAssertTrue(snap.recording)
        XCTAssertTrue(snap.distillEnabled)
        XCTAssertEqual(snap.currentChunkSeq, 2)
        XCTAssertEqual(snap.peakMicDb, -23.5, accuracy: 0.001)
        XCTAssertEqual(snap.peakSystemDb, -41.0, accuracy: 0.001)
        XCTAssertEqual(snap.huskeVersion, "0.11.0")
        XCTAssertEqual(snap.inputDeviceName, "MacBook Pro Microphone")
        XCTAssertEqual(snap.warnings, ["heartbeat": "no audio for 6s"])
        XCTAssertEqual(snap.events.count, 1)
        XCTAssertEqual(snap.events[0].severity, .info)
        XCTAssertEqual(snap.events[0].message, "hi")
        XCTAssertNotNil(snap.chunkStartedAt)
        XCTAssertNotNil(snap.nextRotationAt)
        XCTAssertNotNil(snap.sessionStartedAt)
        XCTAssertNotNil(snap.events[0].ts)
    }

    func testDecodesV1SnapshotWithDefaults() throws {
        let v1Line = """
            {"type":"state","session_id":"20260509T120000_abcd","recording":true,\
            "paused":false,"stopping":false,"current_chunk_seq":2,"queue_depth":1,\
            "screenshots_enabled":false,"distill_enabled":false,\
            "last_saved_name":null}
            """
        let message = try ControlProtocol.decode(line: v1Line)
        guard case .state(let snap) = message else {
            return XCTFail("expected state message")
        }
        XCTAssertNil(snap.lastSavedName)
        XCTAssertEqual(snap.peakMicDb, -120.0)
        XCTAssertEqual(snap.warnings, [:])
        XCTAssertEqual(snap.events, [])
        XCTAssertNil(snap.chunkStartedAt)
        XCTAssertEqual(snap.huskeVersion, "")
        XCTAssertEqual(snap.asrRssMb, 0)
        XCTAssertEqual(snap.distillRssMb, 0)
        XCTAssertEqual(snap.engineRssMb, 0)
    }

    func testDecodesDevices() throws {
        let line = """
            {"type":"devices","devices":[{"index":1,"name":"MacBook Pro Microphone",\
            "channels":1,"sample_rate":48000.0},{"index":3,"name":"AirPods Pro",\
            "channels":1,"sample_rate":24000.0}],"current_index":1}
            """
        let message = try ControlProtocol.decode(line: line)
        guard case .devices(let list) = message else {
            return XCTFail("expected devices message")
        }
        XCTAssertEqual(list.devices.count, 2)
        XCTAssertEqual(list.devices[1].name, "AirPods Pro")
        XCTAssertEqual(list.currentIndex, 1)
    }

    func testUnknownTypeThrows() {
        XCTAssertThrowsError(try ControlProtocol.decode(line: #"{"type":"bogus"}"#))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ControlProtocol.decode(line: "not json"))
    }

    func testEncodeCommandWithoutArg() throws {
        let data = ControlProtocol.encodeCommand(.pauseResume)
        let line = String(data: data, encoding: .utf8)!
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try JSONSerialization.jsonObject(
            with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "cmd")
        XCTAssertEqual(obj["name"] as? String, "pause_resume")
        XCTAssertNil(obj["arg"])
    }

    func testEncodeCommandWithStringArg() throws {
        let data = ControlProtocol.encodeCommand(.setInputDevice, arg: "AirPods Pro")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["name"] as? String, "set_input_device")
        XCTAssertEqual(obj["arg"] as? String, "AirPods Pro")
    }

    func testISO8601ParsesPythonMicroseconds() {
        XCTAssertNotNil(ISO8601.parse("2026-07-21T09:15:32.123456-03:00"))
        XCTAssertNotNil(ISO8601.parse("2026-07-21T09:15:32.123-03:00"))
        XCTAssertNotNil(ISO8601.parse("2026-07-21T09:15:32-03:00"))
        XCTAssertNotNil(ISO8601.parse("2026-07-21T12:15:32Z"))
        XCTAssertNil(ISO8601.parse(""))
        XCTAssertNil(ISO8601.parse("not a date"))
    }

    func testISO8601RoundTripsInstant() throws {
        let date = try XCTUnwrap(ISO8601.parse("2026-07-21T12:00:00.500000+00:00"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_784_635_200.5, accuracy: 0.001)
    }
}
