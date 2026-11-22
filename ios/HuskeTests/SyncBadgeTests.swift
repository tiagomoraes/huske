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

    /// The Mac keeps a recording it will retry by itself at "queued" (or
    /// "received", for the hand-off to the engine) and says so in the detail.
    /// That used to read "next in line".
    func testTheMacRetryingByItselfIsShownAsThat() {
        let retrying = badge(recording(sync: uploaded(.queued, detail: "Will retry after an error: decode failed")))
        XCTAssertEqual(retrying, .retryingOnMac(reason: "decode failed"))
        XCTAssertEqual(retrying.label, "Trying again on your Mac")
        XCTAssertEqual(
            retrying.sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Studio hit a problem with it and will try again: decode failed")
        XCTAssertFalse(retrying.isProblem, "nothing for the user to do")
        XCTAssertFalse(retrying.canRetry)

        XCTAssertEqual(badge(recording(sync: uploaded(.received, detail: "Will retry: engine busy"))),
                       .retryingOnMac(reason: "engine busy"))
        XCTAssertEqual(badge(recording(sync: uploaded(.queued, detail: "Will retry"))), .retryingOnMac(reason: nil))
        XCTAssertEqual(
            SyncBadge.retryingOnMac(reason: nil)
                .sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Studio hit a problem with it and will try again.")
        XCTAssertEqual(badge(recording(sync: uploaded(.queued, detail: "Waiting for the transcriber"))), .queued)
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing, detail: "Will retry: x"))).label, "Transcribing",
                       "only while it waits")
    }

    /// A recording that never reached the Mac was labelled "Couldn't
    /// transcribe".
    func testAFailedSendIsNotAFailedTranscription() {
        var sync = SyncRecord()
        sync.failure = "This recording is too large to send to Studio."
        let failed = badge(recording(sync: sync))

        XCTAssertEqual(failed, .sendFailed(reason: "This recording is too large to send to Studio."))
        XCTAssertEqual(failed.label, "Couldn't send")
        XCTAssertTrue(failed.isProblem)
        XCTAssertTrue(failed.canRetry, "the way out is Retry")
        XCTAssertEqual(failed.ringKind, .failed)
        XCTAssertEqual(failed.tone, .error)
        XCTAssertEqual(failed.sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
                       "This recording is too large to send to Studio.")
        XCTAssertEqual(failed.accessibilityLabel, "Couldn't send: This recording is too large to send to Studio.")

        let onMac = SyncBadge.failed(reason: "no speech model")
        XCTAssertEqual(onMac.label, "Couldn't transcribe")
        XCTAssertTrue(onMac.canRetry)
        XCTAssertEqual(onMac.sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
                       "Studio couldn't transcribe it: no speech model")
        for other in [SyncBadge.queued, .onMac, .waitingForMac, .transcribed, .damaged, .uploading(fraction: 0.3)] {
            XCTAssertFalse(other.canRetry, "\(other)")
        }
    }

    /// The Mac's "part 3 of 3" names the part it is working on. Counting it
    /// as done filled the ring for the whole last part.
    func testTheTranscribingRingFollowsTheMacsProgress() {
        func ring(_ detail: String?, _ progress: Double?) -> StateRing.Kind {
            badge(recording(sync: uploaded(.transcribing, detail: detail, progress: progress))).ringKind
        }
        XCTAssertEqual(ring("Transcribing part 1 of 3", 0), .progress(nil), "nothing done yet: working, not 1/3")
        XCTAssertEqual(ring("Transcribing part 2 of 3", 1.0 / 3), .progress(1.0 / 3))
        XCTAssertEqual(ring("Transcribing part 3 of 3", 2.0 / 3), .progress(2.0 / 3), "not full during the last part")
        XCTAssertEqual(ring(nil, 0.4), .progress(0.4))
        XCTAssertEqual(ring(nil, 7), .progress(1), "clamped")
        // An older Mac sends no progress: the parts before the current one are done.
        XCTAssertEqual(ring("part 3 of 3", nil), .progress(2.0 / 3))
        XCTAssertEqual(ring("part 1 of 3", nil), .progress(nil))
        XCTAssertEqual(ring("Transcribing", nil), .progress(nil))
        XCTAssertEqual(badge(recording(sync: uploaded(.transcribing, detail: "Transcribing part 3 of 3", progress: 2.0 / 3))).label,
                       "Transcribing · 3 of 3", "the words still name the part")
    }

    func testSentencesForTheOrdinaryStates() {
        func say(_ badge: SyncBadge, engine: Bool? = true, fetched: String? = nil) -> String {
            badge.sentence(macName: "Studio", waitingLine: "Ready to send to Studio.", engineAvailable: engine, fetched: fetched)
        }
        XCTAssertEqual(say(.waitingForMac), "Ready to send to Studio.")
        XCTAssertEqual(say(.uploading(fraction: 0.42)), "Sending to Studio · 42%")
        XCTAssertEqual(say(.queued), "On Studio, next in line to be transcribed.")
        XCTAssertEqual(say(.onMac), "On Studio, about to be transcribed.")
        XCTAssertEqual(say(.onMac, engine: false), "On Studio. It's transcribed once Huske's engine is set up there.")
        XCTAssertEqual(say(.transcribing(done: 2, total: 3, fraction: nil)), "Studio is transcribing it · 2 of 3")
        XCTAssertEqual(say(.transcribed, fetched: "2 min ago"), "Transcribed on Studio · 2 min ago")
        XCTAssertEqual(say(.sendFailed(reason: nil)), "Couldn't send this recording.")
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
        XCTAssertEqual(badge(recording(sync: sync)), .sendFailed(reason: "too large"))
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
