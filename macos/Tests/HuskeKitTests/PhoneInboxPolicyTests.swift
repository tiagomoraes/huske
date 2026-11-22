import Foundation
import XCTest

@testable import HuskeKit
import HuskeSync

final class PhoneInboxPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_763_571_780)

    // MARK: answering `commit`

    /// The Mac used to run `huske inbox add` before answering `commit`; the
    /// phone gives up on a reply after 30 s. The answer no longer waits.
    func testCommitIsAnsweredReceivedSoThePhoneKeepsAsking() {
        let ready = PhoneInbox.commitAnswer(recordingID: "r1", engineAvailable: true, now: now)
        XCTAssertEqual(ready.recordingID, "r1")
        XCTAssertEqual(ready.state, .received)
        XCTAssertFalse(ready.state.isTerminal, "a terminal answer would stop the phone from polling")
        XCTAssertEqual(ready.detail, "Handing to the transcriber")
        XCTAssertEqual(ready.updatedAt, now)

        let noEngine = PhoneInbox.commitAnswer(recordingID: "r1", engineAvailable: false, now: now)
        XCTAssertEqual(noEngine.state, .received)
        XCTAssertEqual(noEngine.detail, PhoneInbox.noEngineDetail)
    }

    // MARK: pacing

    /// Each retry waited out the 120 s idle gap: 3.5 minutes for a final
    /// failure to reach the phone.
    func testAnItemWaitingToBeRetriedGetsItsNextPassSoon() {
        XCTAssertEqual(PhoneInbox.passGap(retryPending: false), 120)
        XCTAssertEqual(PhoneInbox.passGap(retryPending: true), 20)
        XCTAssertLessThanOrEqual(PhoneInbox.passGap(retryPending: true), 30)
    }

    func testWhatCountsAsWaitingToBeRetried() {
        let failedOnce = InboxItemStatus(id: "a", rawState: "failed", attempts: 1, error: "boom")
        let failedForGood = InboxItemStatus(id: "b", rawState: "failed", attempts: PhoneInbox.maxAttempts, error: "boom")
        XCTAssertTrue(PhoneInbox.isRetryable(failedOnce))
        XCTAssertFalse(PhoneInbox.isRetryable(failedForGood))
        XCTAssertFalse(PhoneInbox.isRetryable(InboxItemStatus(id: "c", rawState: "queued")))
        // …and the phone is told `queued`, not `failed`, while attempts remain.
        XCTAssertEqual(PhoneInbox.remoteStatus(for: failedOnce, now: now).state, .queued)
        XCTAssertEqual(PhoneInbox.remoteStatus(for: failedForGood, now: now).state, .failed)
    }

    // MARK: progress inside a part

    /// "Transcribing · 1 of 3" sat still for the five minutes a part takes.
    /// The engine now estimates how far the part in flight has got.
    func testProgressMovesInsideAPart() {
        func progress(done: Int, of total: Int, within: Double?) -> Double? {
            PhoneInbox.remoteStatus(
                for: InboxItemStatus(
                    id: "r", rawState: "processing", chunksTotal: total, chunksDone: done, chunkProgress: within),
                now: now
            ).progress
        }
        XCTAssertEqual(progress(done: 0, of: 3, within: nil), 0)
        XCTAssertEqual(progress(done: 0, of: 3, within: 0.3) ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(progress(done: 1, of: 3, within: 0.5) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(progress(done: 1, of: 3, within: nil) ?? -1, 1.0 / 3, accuracy: 1e-9)
        // The estimate tops out below a whole part: never "done" early.
        let nearlyThere = progress(done: 2, of: 3, within: 0.99) ?? 1
        XCTAssertLessThan(nearlyThere, 1)
        XCTAssertGreaterThan(nearlyThere, 2.0 / 3)
        // A stale value on a finished count adds nothing.
        XCTAssertEqual(progress(done: 3, of: 3, within: 0.5), 1)
        XCTAssertNil(progress(done: 0, of: 0, within: 0.5))
    }

    func testChunkProgressIsReadFromStatusJSON() throws {
        func item(_ chunkProgress: String) throws -> InboxItemStatus {
            let json = #"{"id": "r", "state": "processing", "chunks_total": 3, "chunks_done": 1\#(chunkProgress)}"#
            return try XCTUnwrap(PhoneInbox.parseStatus(Data(json.utf8)))
        }
        XCTAssertEqual(try item(#", "chunk_progress": 0.42"#).chunkProgress, 0.42)
        XCTAssertNil(try item("").chunkProgress, "an engine from before the field")
        // Anything that is not a fraction of a part is ignored, not trusted.
        for odd in [#", "chunk_progress": null"#, #", "chunk_progress": 1.7"#, #", "chunk_progress": -0.2"#,
            #", "chunk_progress": true"#, #", "chunk_progress": "half""#, #", "chunk_progress": 0"#]
        {
            XCTAssertNil(try item(odd).chunkProgress, odd)
        }
        // The part number in words is unchanged.
        XCTAssertEqual(
            PhoneInbox.remoteStatus(for: try item(#", "chunk_progress": 0.42"#), now: now).detail,
            "Transcribing part 2 of 3")
    }

    // MARK: Retry from the phone

    func testAReofferOfAFailedRecordingIsARetryRequest() {
        XCTAssertTrue(
            PhoneInbox.shouldRetryOnReoffer(lastRequest: nil, inFlight: false, engineAvailable: true, now: now))
    }

    func testARetryIsNotStackedOnOneInFlight() {
        XCTAssertFalse(
            PhoneInbox.shouldRetryOnReoffer(lastRequest: nil, inFlight: true, engineAvailable: true, now: now))
    }

    func testWithoutAnEngineThereIsNothingToRetryWith() {
        XCTAssertFalse(
            PhoneInbox.shouldRetryOnReoffer(lastRequest: nil, inFlight: false, engineAvailable: false, now: now))
    }

    /// Each retry buys three fresh attempts; a client re-offering in a loop
    /// must not keep the engine on a broken file for ever.
    func testReoffersInQuickSuccessionAreOneRetry() {
        let justNow = now.addingTimeInterval(-5)
        XCTAssertFalse(
            PhoneInbox.shouldRetryOnReoffer(lastRequest: justNow, inFlight: false, engineAvailable: true, now: now))
        let aWhileAgo = now.addingTimeInterval(-PhoneInbox.reofferRetryCooldown)
        XCTAssertTrue(
            PhoneInbox.shouldRetryOnReoffer(lastRequest: aWhileAgo, inFlight: false, engineAvailable: true, now: now))
    }
}
