// The iPhone pane's words for a recording the engine gave up on: plainly
// "Partly transcribed · 2 of 3 parts" when some of it can be read, and
// "Couldn't transcribe" when none can.

import HuskeSync
import XCTest

@testable import HuskeKit

final class PhoneRecordingWordsTests: XCTestCase {
    func testAPartlyTranscribedRecordingSaysHowMuch() {
        XCTAssertEqual(
            PhoneRecordingWords.failed(partsDone: 2, partsTotal: 3), "Partly transcribed · 2 of 3 parts")
        XCTAssertEqual(
            PhoneRecordingWords.failed(partsDone: 1, partsTotal: 12), "Partly transcribed · 1 of 12 parts")
        XCTAssertTrue(PhoneRecordingWords.isPartlyTranscribed(partsDone: 2, partsTotal: 3))
    }

    /// Nothing transcribed, everything transcribed, or no counts at all: not
    /// "partly", and never "0 of 3 parts".
    func testAnythingElseIsAPlainFailure() {
        for (done, total) in [(0, 3), (3, 3), (4, 3), (0, 0), (-1, 3)] as [(Int, Int)] {
            XCTAssertEqual(
                PhoneRecordingWords.failed(partsDone: done, partsTotal: total), "Couldn't transcribe",
                "\(done) of \(total)")
            XCTAssertFalse(PhoneRecordingWords.isPartlyTranscribed(partsDone: done, partsTotal: total))
        }
        XCTAssertEqual(PhoneRecordingWords.failed(partsDone: nil, partsTotal: nil), "Couldn't transcribe")
        XCTAssertEqual(PhoneRecordingWords.failed(partsDone: 2, partsTotal: nil), "Couldn't transcribe")
        XCTAssertEqual(PhoneRecordingWords.failed(partsDone: nil, partsTotal: 3), "Couldn't transcribe")
    }

    /// What the row keeps of a status: the counts of a partly transcribed
    /// failure, and nothing once the recording is anything else.
    func testOnlyAPartialFailureCarriesParts() {
        let failed = RemoteStatus(recordingID: "a", state: .failed, detail: "decode error")
        let partial = failed.withPartialTranscript(done: 2, total: 3)
        XCTAssertEqual(PhoneRecordingWords.parts(of: partial)?.done, 2)
        XCTAssertEqual(PhoneRecordingWords.parts(of: partial)?.total, 3)
        XCTAssertNil(PhoneRecordingWords.parts(of: failed))
        XCTAssertNil(PhoneRecordingWords.parts(of: failed.withPartialTranscript(done: 0, total: 3)))
        // Retried and now queued: the old counts must not linger.
        let requeued = RemoteStatus(recordingID: "a", state: .queued).withPartialTranscript(done: 2, total: 3)
        XCTAssertNil(PhoneRecordingWords.parts(of: requeued))
        XCTAssertNil(PhoneRecordingWords.parts(of: RemoteStatus(recordingID: "a", state: .transcribed)))
    }

    /// End to end with the engine's own status file: a three-part recording
    /// the engine gave up on with part 2 missing.
    func testTheEnginesStatusBecomesThePanesWords() throws {
        let json = """
            {"id": "rec-1", "state": "failed", "attempts": 3, "error": "part 2 could not be decoded",
             "chunks_done": 2, "chunks_total": 3, "missing_chunks": [2],
             "transcripts": ["/tmp/a.md", "/tmp/c.md"]}
            """
        let item = try XCTUnwrap(PhoneInbox.parseStatus(Data(json.utf8)))
        let status = PhoneInbox.remoteStatus(for: item)
        let parts = try XCTUnwrap(PhoneRecordingWords.parts(of: status))
        XCTAssertEqual(
            PhoneRecordingWords.failed(partsDone: parts.done, partsTotal: parts.total),
            "Partly transcribed · 2 of 3 parts")
    }
}
