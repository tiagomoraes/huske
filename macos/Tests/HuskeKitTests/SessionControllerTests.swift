import XCTest

@testable import HuskeKit

@MainActor
final class SessionControllerTests: XCTestCase {
    private func makeSnapshot(
        recording: Bool = true,
        stopping: Bool = false,
        events: [SessionEvent] = []
    ) -> ControlSnapshot {
        ControlSnapshot(
            sessionId: "20260721T090000_abcd",
            recording: recording,
            paused: false,
            stopping: stopping,
            currentChunkSeq: 1,
            queueDepth: 0,
            screenshotsEnabled: false,
            distillEnabled: false,
            events: events
        )
    }

    func testIngestStateUpdatesSnapshot() {
        let controller = SessionController()
        controller.ingest(message: .state(makeSnapshot()))
        XCTAssertEqual(controller.snapshot?.sessionId, "20260721T090000_abcd")
        XCTAssertFalse(controller.isDraining)
        XCTAssertNil(controller.stopRequestedAt)

        controller.ingest(message: .state(makeSnapshot(stopping: true)))
        XCTAssertTrue(controller.isDraining)
        XCTAssertNotNil(controller.stopRequestedAt)
    }

    func testStopRequestFreezesClockImmediatelyAndOnlyOnce() {
        let controller = SessionController()

        controller.requestStop()
        let firstStop = controller.stopRequestedAt
        controller.requestStop()

        XCTAssertNotNil(firstStop)
        XCTAssertEqual(controller.stopRequestedAt, firstStop)
    }

    func testEventLogDeduplicatesAcrossSnapshots() {
        let controller = SessionController()
        let first = SessionEvent(
            rawTimestamp: "2026-07-21T09:00:01-03:00", severity: .info, message: "one")
        let second = SessionEvent(
            rawTimestamp: "2026-07-21T09:00:02-03:00", severity: .warn, message: "two")

        controller.ingest(message: .state(makeSnapshot(events: [first])))
        controller.ingest(message: .state(makeSnapshot(events: [first, second])))
        controller.ingest(message: .state(makeSnapshot(events: [first, second])))

        XCTAssertEqual(controller.eventLog.map(\.message), ["one", "two"])
    }

    func testEventLogTrimsSeenIDsWithTheCap() {
        let controller = SessionController()
        let events = (0..<260).map { i in
            SessionEvent(
                rawTimestamp: "2026-07-21T09:00:00-03:00",
                severity: .info,
                message: "event-\(i)")
        }
        controller.ingest(message: .state(makeSnapshot(events: events)))
        XCTAssertEqual(controller.eventLog.count, 250)
        XCTAssertEqual(controller.eventLog.first?.message, "event-10")
        XCTAssertEqual(controller.eventLog.last?.message, "event-259")
    }

    func testIngestDevices() {
        let controller = SessionController()
        let list = DeviceList(
            devices: [InputDeviceEntry(index: 1, name: "Mic", channels: 1, sampleRate: 48000)],
            currentIndex: 1
        )
        controller.ingest(message: .devices(list))
        XCTAssertEqual(controller.devices, list)
    }

    func testStartEngineWithBrokenBinaryFails() {
        let controller = SessionController()
        controller.startEngine(
            binary: URL(fileURLWithPath: "/tmp/definitely-not-huske-\(UUID().uuidString)"),
            socketPath: "/tmp/hsk-never.sock"
        )
        guard case .failed = controller.phase else {
            return XCTFail("expected failure phase, got \(controller.phase)")
        }
    }

    func testDemoSessionDrivesController() async throws {
        let controller = SessionController()
        let demo = DemoSession(controller: controller)
        demo.start()
        defer { demo.stop() }

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(controller.phase, .active(attached: false))
        XCTAssertNotNil(controller.snapshot)
        XCTAssertEqual(controller.devices?.devices.count, 2)
        XCTAssertTrue(controller.snapshot?.recording ?? false)
    }
}
