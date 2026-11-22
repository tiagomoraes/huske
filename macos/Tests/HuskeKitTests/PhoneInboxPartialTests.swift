// What the phone is told about a recording the engine could not finish:
// a partial transcript to read (transcript.partial) and "the Mac will try
// again" as fields (status.retry). The mapping always fills the extras in;
// HuskeSync holds them back for a phone that did not announce them, so the
// plain fields must stay exactly what older phones were sent.

import HuskeSync
import XCTest

@testable import HuskeKit

final class PhoneInboxPartialTests: XCTestCase {
    private let updated = Date(timeIntervalSince1970: 1_763_571_780)

    private func item(
        state: String, attempts: Int, total: Int = 3, done: Int = 2,
        transcripts: [String] = ["/t/140300_5b0f7e4c_001.md", "/t/140300_5b0f7e4c_003.md"],
        missing: [Int] = [2], error: String? = "chunk 2/3 failed: decode error"
    ) -> InboxItemStatus {
        InboxItemStatus(
            id: "4E1C", rawState: state, updatedAt: updated, attempts: attempts, chunksTotal: total,
            chunksDone: done, transcripts: transcripts, error: error, missingChunks: missing)
    }

    // MARK: status.json

    func testParsesMissingChunks() throws {
        let json = """
            {
              "id": "4E1C", "state": "failed", "attempts": 3,
              "chunks_total": 3, "chunks_done": 2,
              "missing_chunks": [2],
              "chunk_results": {"split": "a3f1", "total": 3, "done": {"1": "/t/1.md", "3": null}},
              "transcripts": ["/t/1.md", "/t/3.md"],
              "error": "chunk 2/3 failed: decode error"
            }
            """
        let parsed = try XCTUnwrap(PhoneInbox.parseStatus(Data(json.utf8)))
        XCTAssertEqual(parsed.missingChunks, [2])
        XCTAssertEqual(parsed.chunksDone, 2)
        XCTAssertTrue(PhoneInbox.hasPartialTranscript(parsed))
    }

    func testAStatusWithoutMissingChunksHasNone() throws {
        // As every engine before this one writes it.
        let json = #"{"id": "4E1C", "state": "failed", "attempts": 3, "transcripts": ["/t/1.md"], "error": "x"}"#
        let parsed = try XCTUnwrap(PhoneInbox.parseStatus(Data(json.utf8)))
        XCTAssertEqual(parsed.missingChunks, [])
        XCTAssertFalse(PhoneInbox.hasPartialTranscript(parsed), "an older engine's leftovers are not offered")
        let odd = try XCTUnwrap(
            PhoneInbox.parseStatus(Data(#"{"id": "x", "state": "failed", "missing_chunks": [true, "2", 0, 3]}"#.utf8)))
        XCTAssertEqual(odd.missingChunks, [3])
    }

    // MARK: partial

    func testAFailureForGoodWithFinishedPartsIsMarkedPartial() {
        let status = PhoneInbox.remoteStatus(for: item(state: "failed", attempts: 3))
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.detail, "chunk 2/3 failed: decode error")
        XCTAssertEqual(status.partial, true)
        XCTAssertEqual(status.partsDone, 2)
        XCTAssertEqual(status.partsTotal, 3)
        XCTAssertNil(status.retrying)
        // What a phone without the capability is sent: the failure as it was.
        XCTAssertEqual(
            status.limited(to: []),
            RemoteStatus(
                recordingID: "4E1C", state: .failed, detail: "chunk 2/3 failed: decode error",
                updatedAt: updated))
    }

    func testAFailureWithNothingTranscribedIsNotPartial() {
        let nothing = item(state: "failed", attempts: 3, done: 0, transcripts: [], missing: [1, 2, 3])
        XCTAssertFalse(PhoneInbox.hasPartialTranscript(nothing))
        XCTAssertNil(PhoneInbox.remoteStatus(for: nothing).partial)
        XCTAssertNil(PhoneInbox.partialTranscript(for: nothing))
        // Parts that were silent leave nothing to read either.
        let silent = item(state: "failed", attempts: 3, done: 2, transcripts: [], missing: [2])
        XCTAssertNil(PhoneInbox.remoteStatus(for: silent).partial)
    }

    func testOnlyAFailureForGoodIsPartial() {
        for (state, attempts) in [("queued", 0), ("processing", 2), ("done", 1), ("failed", 1)] {
            let other = item(state: state, attempts: attempts)
            XCTAssertFalse(PhoneInbox.hasPartialTranscript(other), state)
            XCTAssertNil(PhoneInbox.remoteStatus(for: other).partial, state)
            XCTAssertNil(PhoneInbox.partialTranscript(for: other) { _ in "text" }, state)
        }
    }

    func testThePartialTranscriptIsTheFinishedPartsInOrder() {
        let files = [
            "/t/140300_5b0f7e4c_001.md": "---\nchunk_seq: 1\n---\n# 14:03 – 14:18\n\n[14:03:01 · mic] one",
            "/t/140300_5b0f7e4c_003.md": "---\nchunk_seq: 3\n---\n# 14:33 – 14:40\n\n[14:33:10 · mic] three",
        ]
        let failed = item(state: "failed", attempts: 3)
        XCTAssertEqual(
            PhoneInbox.partialTranscript(for: failed) { files[$0] },
            "# 14:03 – 14:18\n\n[14:03:01 · mic] one\n\n# 14:33 – 14:40\n\n[14:33:10 · mic] three")
        // A whole transcript is only ever a finished item's.
        XCTAssertNil(PhoneInbox.transcript(for: failed))
        // Nothing readable: nothing to serve.
        XCTAssertNil(PhoneInbox.partialTranscript(for: failed) { _ in nil })
    }

    // MARK: retrying

    func testAFailureWithAttemptsLeftIsRetryingWithItsCount() {
        let status = PhoneInbox.remoteStatus(for: item(state: "failed", attempts: 1))
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.retrying, true)
        XCTAssertEqual(status.attempt, 2, "the try that comes next")
        XCTAssertEqual(status.maxAttempts, PhoneInbox.maxAttempts)
        XCTAssertNil(status.partial, "not final: nothing is handed over yet")
        // Phones without status.retry recognise the state by this text.
        XCTAssertEqual(status.detail, "Will retry after an error: chunk 2/3 failed: decode error")
        XCTAssertEqual(
            status.limited(to: []),
            RemoteStatus(
                recordingID: "4E1C", state: .queued,
                detail: "Will retry after an error: chunk 2/3 failed: decode error", updatedAt: updated))
    }

    func testOtherStatesAreNotRetrying() {
        for (state, attempts) in [("queued", 0), ("processing", 2), ("done", 1), ("failed", 3)] {
            let status = PhoneInbox.remoteStatus(for: item(state: state, attempts: attempts))
            XCTAssertNil(status.retrying, state)
            XCTAssertNil(status.attempt, state)
            XCTAssertNil(status.maxAttempts, state)
        }
    }

    func testAHandOffThatFailedIsRetryingWithoutACount() {
        let status = PhoneInbox.handOffRetryStatus(
            recordingID: "4E1C", message: "engine busy", now: updated)
        XCTAssertEqual(status.state, .received)
        XCTAssertEqual(status.detail, "Will retry: engine busy")
        XCTAssertEqual(status.retrying, true)
        XCTAssertNil(status.attempt)
        XCTAssertNil(status.maxAttempts)
        // The same while it waits in the pending folder, from the pane's line.
        XCTAssertEqual(
            PhoneInbox.pendingStatus(recordingID: "4E1C", detail: "Will retry: engine busy", now: updated),
            status)
        let waiting = PhoneInbox.pendingStatus(
            recordingID: "4E1C", detail: PhoneInbox.handingOffDetail, now: updated)
        XCTAssertNil(waiting.retrying)
        XCTAssertEqual(waiting.detail, PhoneInbox.handingOffDetail)
    }
}
