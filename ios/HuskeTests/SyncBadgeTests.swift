import XCTest
@testable import Huske

final class SyncBadgeTests: XCTestCase {
    private func recording(capture: CaptureState = .complete, sync: SyncRecord = SyncRecord(),
                           transcript: TranscriptRecord? = nil) -> Recording {
        Recording(id: "r", title: "t", startedAt: Date(), fileName: "r.m4a",
                  capture: capture, sync: sync, transcript: transcript)
    }

    private func uploaded(_ stage: RemoteStage, detail: String? = nil, progress: Double? = nil) -> SyncRecord {
        SyncRecord(macID: "mac", uploadedAt: Date(),
                   remote: RemoteSnapshot(stage: stage, detail: detail, progress: progress, updatedAt: Date()))
    }

    private func badge(_ r: Recording, paired: Bool = true, upload: Double? = nil) -> SyncBadge {
        SyncBadge(recording: r, isPaired: paired, uploadFraction: upload)
    }

    func testCaptureStatesWin() {
        XCTAssertEqual(badge(recording(capture: .inProgress)), .recording)
        XCTAssertEqual(badge(recording(capture: .inProgress), upload: 0.5), .recording)
        XCTAssertEqual(badge(recording(capture: .damaged)), .damaged)
    }

    func testLocalStates() {
        XCTAssertEqual(badge(recording(), paired: false), .onPhone)
        XCTAssertEqual(badge(recording()), .waitingForMac)
        XCTAssertEqual(badge(recording(), upload: 0.42), .uploading(fraction: 0.42))
        XCTAssertEqual(badge(recording(), upload: 1.7), .uploading(fraction: 1))
        XCTAssertEqual(badge(recording(), upload: 0.42).label, "Sending · 42%")
    }

    func testRemoteStates() {
        XCTAssertEqual(badge(recording(sync: uploaded(.received))), .onMac)
        XCTAssertEqual(badge(recording(sync: uploaded(.queued))), .queued)
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribed))), .transcribed)
        XCTAssertEqual(badge(recording(sync: uploaded(.unknown))), .waitingForMac)
        XCTAssertEqual(badge(recording(sync: uploaded(.receiving))), .waitingForMac)
        XCTAssertEqual(badge(recording(sync: uploaded(.failed, detail: "no audio"))), .failed(reason: "no audio"))
    }

    func testTranscribingLabels() {
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing, detail: "2/3 chunks"))).label, "Transcribing · 2 of 3")
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing, detail: "chunk 2 of 3"))).label, "Transcribing · 2 of 3")
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing, progress: 0.4))).label, "Transcribing · 40%")
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing))).label, "Transcribing")
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing, detail: "1/1"))).label, "Transcribing",
                       "a single part says nothing useful as 1/1")
    }

    func testFailureAndTranscriptPrecedence() {
        var sync = SyncRecord()
        sync.failure = "too large"
        XCTAssertEqual(badge(recording(sync: sync)), .failed(reason: "too large"))
        XCTAssertEqual(badge(recording(sync: sync), upload: 0.1), .uploading(fraction: 0.1),
                       "a live retry shows progress over the stale failure")

        let transcript = TranscriptRecord(markdown: "x", fetchedAt: Date())
        XCTAssertEqual(badge(recording(sync: uploaded(.failed), transcript: transcript)), .transcribed)
        XCTAssertEqual(badge(recording(transcript: transcript), paired: false), .transcribed)
    }

    func testToneAndLiveness() {
        XCTAssertEqual(SyncBadge.transcribed.tone, .ok)
        XCTAssertEqual(SyncBadge.uploading(fraction: 0.1).tone, .active)
        XCTAssertTrue(SyncBadge.uploading(fraction: 0.1).isLive)
        XCTAssertFalse(SyncBadge.queued.isLive)
        XCTAssertEqual(SyncBadge.failed(reason: nil).tone, .error)
    }

    func testChunkCountParsing() {
        XCTAssertEqual(SyncBadge.chunkCounts(in: "3/5")?.done, 3)
        XCTAssertEqual(SyncBadge.chunkCounts(in: "3 of 5 chunks")?.total, 5)
        XCTAssertNil(SyncBadge.chunkCounts(in: "6/5"))
        XCTAssertNil(SyncBadge.chunkCounts(in: "working"))
        XCTAssertNil(SyncBadge.chunkCounts(in: nil))
    }
}
