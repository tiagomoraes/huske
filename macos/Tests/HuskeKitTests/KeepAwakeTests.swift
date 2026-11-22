import Foundation
import XCTest

@testable import HuskeKit
import HuskeSync

/// The Mac stays awake while a phone recording is in flight — and only then.
@MainActor
final class KeepAwakeTests: XCTestCase {
    /// Counts the system activity instead of taking one.
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var _began = 0
        private var _ended = 0
        var began: Int { lock.withLock { _began } }
        var ended: Int { lock.withLock { _ended } }
        var active: Int { lock.withLock { _began - _ended } }
        func begin(_ reason: String) -> AnyObject {
            lock.withLock { _began += 1 }
            return NSObject()
        }
        func end(_ token: AnyObject) { lock.withLock { _ended += 1 } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_763_571_780)
        var now: Date { lock.withLock { _now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
    }

    private func make() -> (KeepAwake, Activity, Clock) {
        let (activity, clock) = (Activity(), Clock())
        let keeper = KeepAwake(
            begin: { activity.begin($0) }, end: { activity.end($0) }, now: { clock.now })
        return (keeper, activity, clock)
    }

    private func manifest(_ id: String) -> RecordingManifest {
        RecordingManifest(
            id: id, title: "t", startedAt: Date(timeIntervalSince1970: 1_763_571_780), durationSeconds: 60,
            byteCount: 1_000_000, sha256: String(repeating: "ab", count: 32), fileExtension: "m4a",
            contentType: "audio/mp4", sampleRate: 48_000, channels: 1, timeZone: "UTC",
            deviceName: "iPhone de Teste")
    }

    func testAnIdleMacIsNeverHeldAwake() {
        let (keeper, activity, _) = make()
        XCTAssertFalse(keeper.isHolding)
        keeper.sweep()
        keeper.release("nothing")
        keeper.releaseAll()
        XCTAssertEqual(activity.began, 0)
    }

    func testOneActivityCoversOverlappingWorkAndEndsWithTheLast() {
        let (keeper, activity, _) = make()
        keeper.hold("a", for: 60)
        keeper.hold("b", for: 60)
        XCTAssertTrue(keeper.isHolding)
        XCTAssertEqual(activity.began, 1, "one assertion, however much is going on")

        keeper.release("a")
        XCTAssertTrue(keeper.isHolding)
        XCTAssertEqual(activity.ended, 0)
        keeper.release("b")
        XCTAssertFalse(keeper.isHolding)
        XCTAssertEqual(activity.ended, 1)
        keeper.release("b")
        XCTAssertEqual(activity.ended, 1, "released twice, ended once")
    }

    /// A phone that walks away mid-upload sends no "I stopped": the lease
    /// must run out by itself.
    func testALeaseThatIsNotRenewedRunsOut() {
        let (keeper, activity, clock) = make()
        keeper.hold("upload", for: 45)
        clock.advance(44)
        keeper.sweep()
        XCTAssertTrue(keeper.isHolding)
        clock.advance(2)
        keeper.sweep()
        XCTAssertFalse(keeper.isHolding)
        XCTAssertEqual(activity.active, 0)
    }

    func testRenewingKeepsItHeld() {
        let (keeper, activity, clock) = make()
        keeper.hold("upload", for: 45)
        for _ in 0..<10 {
            clock.advance(40)
            keeper.hold("upload", for: 45)  // a chunk arrived
            keeper.sweep()
            XCTAssertTrue(keeper.isHolding)
        }
        XCTAssertEqual(activity.began, 1, "renewals must not churn the assertion")
    }

    func testAnUploadHoldsTheMacAwakeFromOfferToCommit() {
        let (keeper, activity, clock) = make()
        keeper.note(.uploadStarted(manifest("r1"), offset: 0, deviceID: "phone"))
        XCTAssertTrue(keeper.isHolding)
        XCTAssertEqual(keeper.reasons, [KeepAwake.uploadKey("r1")])
        for step in 1...20 {
            clock.advance(30)
            keeper.note(.uploadProgress(recordingID: "r1", received: Int64(step) * 50_000, total: 1_000_000))
            keeper.sweep()
        }
        XCTAssertTrue(keeper.isHolding, "ten minutes of steady chunks")
        keeper.note(.uploadVerified(manifest("r1"), deviceID: "phone"))
        XCTAssertFalse(keeper.isHolding)
        XCTAssertEqual(activity.active, 0)
    }

    func testAFailedChecksumReleases() {
        let (keeper, _, _) = make()
        keeper.note(.uploadStarted(manifest("r1"), offset: 0, deviceID: "phone"))
        keeper.note(.uploadFailed(recordingID: "r1", reason: "checksum mismatch"))
        XCTAssertFalse(keeper.isHolding)
    }

    func testAPhoneDisconnectingReleasesItsUploadsOnly() {
        let (keeper, _, _) = make()
        keeper.note(.uploadStarted(manifest("mine"), offset: 0, deviceID: "phone-a"))
        keeper.note(.uploadStarted(manifest("theirs"), offset: 0, deviceID: "phone-b"))
        keeper.note(.deviceDisconnected(deviceID: "phone-a"))
        XCTAssertEqual(keeper.reasons, [KeepAwake.uploadKey("theirs")])
        keeper.note(.deviceDisconnected(deviceID: "phone-b"))
        XCTAssertFalse(keeper.isHolding)
    }

    func testEventsThatAreNotWorkDoNotHold() {
        let (keeper, activity, _) = make()
        keeper.note(.listening(port: 51_234))
        keeper.note(.listenerFailed("down"))
        keeper.note(.deviceDisconnected(deviceID: "nobody"))
        XCTAssertEqual(activity.began, 0)
    }

    func testHandOffAndInboxPassHoldUntilReleased() {
        let (keeper, _, clock) = make()
        keeper.hold(KeepAwake.handOffKey("r1"), for: KeepAwake.handOffLease)
        keeper.hold(KeepAwake.processKey, for: KeepAwake.processLease)
        keeper.release(KeepAwake.handOffKey("r1"))
        XCTAssertTrue(keeper.isHolding, "the transcription pass is still running")
        // A pass that never reports back is bounded by its own watchdog.
        clock.advance(KeepAwake.processLease + 1)
        keeper.sweep()
        XCTAssertFalse(keeper.isHolding)
    }

    func testStoppingReceivingReleasesEverything() {
        let (keeper, activity, _) = make()
        keeper.note(.uploadStarted(manifest("r1"), offset: 0, deviceID: "phone"))
        keeper.hold(KeepAwake.processKey, for: 600)
        keeper.releaseAll()
        XCTAssertFalse(keeper.isHolding)
        XCTAssertEqual(activity.active, 0)
    }

    /// No caller has to remember to sweep: it runs out on its own clock.
    func testItExpiresByItselfInRealTime() async throws {
        let activity = Activity()
        let keeper = KeepAwake(begin: { activity.begin($0) }, end: { activity.end($0) })
        keeper.hold("upload", for: 0.15)
        XCTAssertTrue(keeper.isHolding)
        for _ in 0..<100 where keeper.isHolding {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(keeper.isHolding, "nothing released it and it never expired")
        XCTAssertEqual(activity.active, 0)
    }

    func testAKeeperThatGoesAwayEndsItsActivity() {
        let activity = Activity()
        var keeper: KeepAwake? = KeepAwake(begin: { activity.begin($0) }, end: { activity.end($0) })
        keeper?.hold("upload", for: 600)
        XCTAssertEqual(activity.active, 1)
        keeper = nil
        XCTAssertEqual(activity.active, 0, "an abandoned assertion would keep the Mac awake for good")
    }

    /// The real thing: taking and ending the system activity must not trap.
    func testTheSystemActivityCanBeTakenAndEnded() {
        let keeper = KeepAwake()
        keeper.hold("upload", for: 5)
        XCTAssertTrue(keeper.isHolding)
        keeper.releaseAll()
        XCTAssertFalse(keeper.isHolding)
    }
}
