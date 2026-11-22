// A recording the Mac could only transcribe part of, and the Mac saying "I
// will try again" as fields instead of words (sync-protocol.md §
// RemoteStatus). Both are extras a Mac only sends once both sides announced
// them, so every path here has its older-Mac twin.

import HuskeSync
import Network
import XCTest
@testable import Huske

// MARK: - a Mac that can hand over parts

/// Answers with whole `RemoteStatus` values and, when `offersParts`, the
/// parts of a recording it gave up on.
private final class PartsMac: @unchecked Sendable {
    struct State {
        var statuses: [String: RemoteStatus] = [:]
        var whole: [String: String] = [:]
        var parts: [String: String] = [:]
        /// Huske.app with `transcript.partial`. Off: the Mac as it was.
        var offersParts = true
        /// Offering a failed recording queues it again (the phone's Retry).
        var requeuesFailedOnOffer = true
        var offered: [String] = []
        var transcriptRequests: [String] = []
        var statusRequests = 0
        var connects = 0
    }

    let macID = UUID().uuidString
    let name = "Studio"
    private let lock = NSLock()
    private var state = State()

    func with<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var pairing: PairedMac {
        PairedMac(macID: macID, macName: name, deviceID: "device", key: Data(repeating: 7, count: 32),
                  pairedAt: Date())
    }
}

private struct PartsConnector: MacConnecting {
    let mac: PartsMac

    func connect(timeout: TimeInterval) async throws -> any MacSession {
        mac.with { $0.connects += 1 }
        return PartsSession(mac: mac)
    }
}

private struct PartsSession: MacSession {
    let mac: PartsMac

    var welcome: Welcome {
        Welcome(protocolVersion: 1, macID: mac.macID, macName: mac.name, serverVersion: "test",
                engineAvailable: true,
                capabilities: mac.with { $0.offersParts } ? SyncConstants.capabilities : [])
    }

    /// What this Mac puts on the wire: an older one has no extras to send.
    private func sent(_ status: RemoteStatus) -> RemoteStatus {
        status.limited(to: mac.with { $0.offersParts } ? Set(SyncConstants.capabilities) : [])
    }

    func upload(manifest: RecordingManifest, fileURL: URL,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus {
        let status = mac.with { state -> RemoteStatus in
            state.offered.append(manifest.id)
            if state.statuses[manifest.id]?.state == .failed, state.requeuesFailedOnOffer {
                state.statuses[manifest.id] = RemoteStatus(recordingID: manifest.id, state: .queued)
            }
            return state.statuses[manifest.id] ?? RemoteStatus(recordingID: manifest.id, state: .queued)
        }
        return sent(status)
    }

    func status(_ recordingIDs: [String]) async throws -> [RemoteStatus] {
        let statuses = mac.with { state -> [RemoteStatus] in
            state.statusRequests += 1
            return recordingIDs.map { state.statuses[$0] ?? .unknown($0) }
        }
        return statuses.map(sent)
    }

    func transcript(_ recordingID: String) async throws -> String? {
        try await fetchTranscript(recordingID).flatMap { $0.isPartial ? nil : $0.text }
    }

    func fetchTranscript(_ recordingID: String) async throws -> FetchedTranscript? {
        mac.with { state in
            state.transcriptRequests.append(recordingID)
            if let text = state.whole[recordingID] { return FetchedTranscript(text: text) }
            if state.offersParts, let text = state.parts[recordingID] {
                return FetchedTranscript(text: text, isPartial: true)
            }
            return nil
        }
    }

    func close() async {}
}

// MARK: - the model

final class PartialTranscriptModelTests: XCTestCase {
    private let partsText = "[14:03:01 · mic] part one\n\n[14:33:10 · mic] part three"

    private func recording(_ stage: RemoteStage, partial: Bool? = nil, done: Int? = nil, total: Int? = nil,
                           detail: String? = nil) -> Recording {
        Recording(
            id: "r", title: "t", startedAt: Date(), fileName: "r.m4a", capture: .complete,
            sync: SyncRecord(
                macID: "mac", uploadedAt: Date(),
                remote: RemoteSnapshot(stage: stage, detail: detail, updatedAt: Date(), partial: partial,
                                       partsDone: done, partsTotal: total)))
    }

    func testAFailureWithPartsOnOfferWantsThemFetched() {
        let failed = recording(.failed, partial: true, done: 2, total: 3)
        XCTAssertTrue(failed.needsTranscript(from: "mac"))
        XCTAssertFalse(failed.needsTranscript(from: "other"))
        XCTAssertFalse(failed.awaitsRemote(on: "mac"), "the Mac gave up: nothing to poll for")
        // A plain failure, as an older Mac reports every failure: nothing to fetch.
        XCTAssertFalse(recording(.failed).needsTranscript(from: "mac"))
        XCTAssertFalse(recording(.queued, partial: true).needsTranscript(from: "mac"))
    }

    func testThePartsAreKeptApartFromATranscript() {
        var r = recording(.failed, partial: true, done: 2, total: 3)
        r.storeFetchedTranscript(partsText, isPartial: true)

        XCTAssertNil(r.transcript, "not transcribed: Retry, re-sending and the badge all read this")
        XCTAssertEqual(r.partialTranscript?.markdown, partsText)
        XCTAssertEqual(r.partialTranscript?.partsDone, 2)
        XCTAssertEqual(r.partialTranscript?.partsTotal, 3)
        XCTAssertFalse(r.isTranscriptAvailable)
        XCTAssertFalse(r.needsTranscript(from: "mac"), "fetched once")
        XCTAssertEqual(r.sync.remote?.stage, .failed)
    }

    /// A retry that failed again may have got further: fetch what there is now.
    func testMorePartsThanBeforeAreFetchedAgain() {
        var r = recording(.failed, partial: true, done: 2, total: 4)
        r.storeFetchedTranscript(partsText, isPartial: true)
        r.sync.remote?.partsDone = 3
        XCTAssertTrue(r.needsTranscript(from: "mac"))
        r.storeFetchedTranscript(partsText + "\n\n[14:48:00 · mic] part four", isPartial: true)
        XCTAssertEqual(r.partialTranscript?.partsDone, 3)
        XCTAssertFalse(r.needsTranscript(from: "mac"))
    }

    func testTheWholeTranscriptReplacesTheParts() {
        var r = recording(.failed, partial: true, done: 2, total: 3)
        r.storeFetchedTranscript(partsText, isPartial: true)
        r.sync.remote = RemoteSnapshot(stage: .transcribed, updatedAt: Date())
        XCTAssertTrue(r.needsTranscript(from: "mac"))

        r.storeFetchedTranscript("[14:03:01 · mic] all of it", isPartial: false)

        XCTAssertEqual(r.transcript?.markdown, "[14:03:01 · mic] all of it")
        XCTAssertNil(r.partialTranscript)
        XCTAssertFalse(r.needsTranscript(from: "mac"))
    }

    /// The Mac finished it meanwhile (it was retried there): asked for the
    /// parts, got the whole thing.
    func testAWholeTranscriptWhereOnlyPartsWereExpectedIsATranscript() {
        var r = recording(.failed, partial: true, done: 2, total: 3, detail: "chunk 2/3 failed")
        r.storeFetchedTranscript("[14:03:01 · mic] all of it", isPartial: false)
        XCTAssertEqual(r.transcript?.markdown, "[14:03:01 · mic] all of it")
        XCTAssertEqual(r.sync.remote?.stage, .transcribed)
        XCTAssertNil(r.sync.remote?.partial)
        XCTAssertNil(r.sync.remote?.detail)
    }

    func testPartsThatAreNoLongerOnOfferAreNotAskedForAgain() {
        var r = recording(.failed, partial: true, done: 2, total: 3)
        r.storeFetchedTranscript(nil, isPartial: false)
        XCTAssertNil(r.transcript)
        XCTAssertNil(r.partialTranscript)
        XCTAssertFalse(r.needsTranscript(from: "mac"))
        XCTAssertEqual(r.sync.remote?.stage, .failed)
    }

    func testNothingToReadForATranscribedRecordingStillMeansNoSpeech() {
        var r = recording(.transcribed)
        r.storeFetchedTranscript(nil, isPartial: false)
        XCTAssertNotNil(r.transcript)
        XCTAssertNil(r.transcript?.markdown)
    }

    /// A library saved before any of this existed must still load.
    func testALibrarySavedByAnOlderBuildDecodes() throws {
        let json = """
            {"id":"r","title":"t","startedAt":0,"duration":12,"fileName":"r.m4a","byteCount":16,
             "timeZoneID":"America/Sao_Paulo","capture":"complete",
             "sync":{"macID":"mac","uploadedAt":10,"attempts":1,
                     "remote":{"stage":"failed","detail":"decode failed","updatedAt":20}}}
            """
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sync.remote?.stage, .failed)
        XCTAssertNil(decoded.sync.remote?.partial)
        XCTAssertNil(decoded.sync.remote?.retrying)
        XCTAssertNil(decoded.partialTranscript)

        var current = recording(.failed, partial: true, done: 2, total: 3)
        current.storeFetchedTranscript(partsText, isPartial: true)
        let roundTrip = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip, current)
    }

    // MARK: the badge

    private func badge(_ r: Recording) -> SyncBadge {
        SyncBadge(recording: r, isPaired: true, uploadFraction: nil)
    }

    func testAPartlyTranscribedRecordingSaysSoQuietlyAndKeepsRetry() {
        var r = recording(.failed, partial: true, done: 2, total: 3, detail: "chunk 2/3 failed: decode error")
        XCTAssertEqual(badge(r), .failed(reason: "chunk 2/3 failed: decode error"), "until the parts are here")
        r.storeFetchedTranscript(partsText, isPartial: true)
        let partial = badge(r)

        XCTAssertEqual(partial, .partial(done: 2, total: 3))
        XCTAssertEqual(partial.label, "Partly transcribed")
        XCTAssertEqual(
            partial.sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Part of this recording couldn't be transcribed — 2 of 3 parts are below.")
        XCTAssertTrue(partial.canRetry, "Retry stays")
        XCTAssertTrue(partial.isPartial)
        XCTAssertFalse(partial.isProblem, "a quiet note, not an alarm")
        XCTAssertFalse(partial.isLive)
        XCTAssertEqual(partial.ringKind, .held)
        XCTAssertEqual(partial.accessibilityLabel, "Partly transcribed: 2 of 3 parts")
        // Without counts it still reads as a sentence.
        XCTAssertEqual(
            SyncBadge.partial(done: nil, total: nil)
                .sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Part of this recording couldn't be transcribed — what Studio got is below.")
    }

    /// While the Mac tries again the line under the title says that; the
    /// parts stay on screen with a note of their own.
    func testWhileTheMacTriesAgainThePartsStayWithTheirOwnNote() {
        var r = recording(.failed, partial: true, done: 2, total: 3)
        r.storeFetchedTranscript(partsText, isPartial: true)
        r.sync.remote = RemoteSnapshot(stage: .transcribing, detail: "Transcribing part 3 of 3", updatedAt: Date())

        XCTAssertFalse(badge(r).isPartial)
        XCTAssertEqual(badge(r).label, "Transcribing · 3 of 3")
        XCTAssertEqual(r.partialTranscript?.earlierTryNote, "2 of 3 parts, from the earlier try.")
        XCTAssertEqual(
            PartialTranscript(markdown: "x", fetchedAt: Date()).earlierTryNote,
            "Part of the recording, from the earlier try.")
    }

    func testTheWholeTranscriptWinsOverEverything() {
        var r = recording(.failed, partial: true, done: 2, total: 3)
        r.storeFetchedTranscript(partsText, isPartial: true)
        r.transcript = TranscriptRecord(markdown: "all", fetchedAt: Date())
        XCTAssertEqual(badge(r), .transcribed)
    }

    // MARK: "will retry" as fields

    private func retrying(_ stage: RemoteStage, detail: String?, attempt: Int? = nil, of max: Int? = nil) -> Recording {
        Recording(
            id: "r", title: "t", startedAt: Date(), fileName: "r.m4a", capture: .complete,
            sync: SyncRecord(
                macID: "mac", uploadedAt: Date(),
                remote: RemoteSnapshot(stage: stage, detail: detail, updatedAt: Date(), retrying: true,
                                       attempt: attempt, maxAttempts: max)))
    }

    /// The fields decide; the words are only the reason. A Mac that rewords
    /// its detail is still understood.
    func testTheFieldsAreUsedWhenTheMacSendsThem() {
        let reworded = badge(retrying(.queued, detail: "Trying once more: decode failed", attempt: 2, of: 3))
        XCTAssertEqual(reworded, .retryingOnMac(reason: "Trying once more: decode failed", attempt: 2, maxAttempts: 3))
        XCTAssertEqual(reworded.label, "Trying again on your Mac")
        XCTAssertFalse(reworded.canRetry)
        XCTAssertFalse(reworded.isProblem)

        let familiar = badge(retrying(.queued, detail: "Will retry after an error: decode failed", attempt: 2, of: 3))
        XCTAssertEqual(familiar, .retryingOnMac(reason: "decode failed", attempt: 2, maxAttempts: 3))
        XCTAssertEqual(
            familiar.sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Studio hit a problem with it and will try again (attempt 2 of 3): decode failed")

        // The hand-off to the engine is retried without a count.
        let handOff = badge(retrying(.received, detail: "Will retry: engine busy"))
        XCTAssertEqual(handOff, .retryingOnMac(reason: "engine busy"))
        XCTAssertEqual(
            handOff.sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Studio hit a problem with it and will try again: engine busy")
        XCTAssertEqual(badge(retrying(.queued, detail: nil)), .retryingOnMac(reason: nil))
    }

    /// An older Mac has only its words: they are still read.
    func testTheWordsAreStillReadFromAnOlderMac() {
        let old = Recording(
            id: "r", title: "t", startedAt: Date(), fileName: "r.m4a", capture: .complete,
            sync: SyncRecord(
                macID: "mac", uploadedAt: Date(),
                remote: RemoteSnapshot(stage: .queued, detail: "Will retry after an error: decode failed",
                                       updatedAt: Date())))
        XCTAssertEqual(badge(old), .retryingOnMac(reason: "decode failed"))
        XCTAssertEqual(
            badge(old).sentence(macName: "Studio", waitingLine: "", engineAvailable: true, fetched: nil),
            "Studio hit a problem with it and will try again: decode failed")
        // And a transcribing recording is never "retrying", whatever came with it.
        XCTAssertEqual(badge(retrying(.transcribing, detail: "Transcribing part 1 of 2")).label,
                       "Transcribing · 1 of 2")
    }
}

// MARK: - through SyncManager

@MainActor
final class PartialTranscriptSyncTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var library: LibraryStore!
    private var managers: [SyncManager] = []

    private let partsText = "[14:03:01 · mic] part one\n\n[14:33:10 · mic] part three"
    private let wholeText = "[14:03:01 · mic] part one\n\n[14:18:05 · mic] part two\n\n[14:33:10 · mic] part three"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PartialTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "PartialTranscriptTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library = LibraryStore(rootDirectory: directory)
    }

    override func tearDown() async throws {
        for manager in managers { manager.forgetMac() }
        managers = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManager(_ mac: PartsMac, presence: FakePresence? = nil) -> SyncManager {
        defaults.set(mac.macID, forKey: "sync.confirmedMacID")
        let manager = SyncManager(
            library: library,
            pairingStore: InMemoryPairingStore(mac.pairing),
            defaults: defaults,
            defaultDeviceName: "Test iPhone",
            makeConnector: { _, _ in PartsConnector(mac: mac) },
            makePresence: { _ in presence },
            retryDelay: { _ in .milliseconds(50) },
            applicationIsInBackground: { false },
            makePathSource: { nil })
        managers.append(manager)
        return manager
    }

    /// A recording the Mac already holds and is still working on.
    private func addQueued(_ id: String, on mac: PartsMac) {
        let recording = Recording(
            id: id, title: "Recording \(id)", startedAt: Date().addingTimeInterval(-600), duration: 1800,
            fileName: "\(id).m4a", byteCount: 16, capture: .complete,
            sync: SyncRecord(macID: mac.macID, uploadedAt: Date(),
                             remote: RemoteSnapshot(stage: .queued, updatedAt: Date())))
        try? Data("synthetic audio \(id)".utf8).write(to: library.audioURL(for: recording))
        library.insert(recording)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func gaveUpWithParts(_ id: String) -> RemoteStatus {
        RemoteStatus(recordingID: id, state: .failed, detail: "chunk 2/3 failed: decode error")
            .withPartialTranscript(done: 2, total: 3)
    }

    func testThePartsOfAFailedRecordingAreFetchedShownAndReplacedByARetry() async {
        let mac = PartsMac()
        mac.with {
            $0.statuses["a"] = self.gaveUpWithParts("a")
            $0.parts["a"] = self.partsText
        }
        addQueued("a", on: mac)
        let sync = makeManager(mac)

        sync.syncNow(.manual)
        let fetched = await waitUntil { self.library.recording(id: "a")?.partialTranscript != nil }
        XCTAssertTrue(fetched)
        _ = await waitUntil { !sync.isRunning }

        var recording = library.recording(id: "a")
        XCTAssertEqual(recording?.partialTranscript?.markdown, partsText)
        XCTAssertNil(recording?.transcript, "still not transcribed")
        XCTAssertEqual(recording.map(sync.badge(for:)), .partial(done: 2, total: 3))
        XCTAssertEqual(mac.with { $0.transcriptRequests }, ["a"], "asked once")

        // Retry: offered again, the Mac queues it, and this time it works.
        sync.retry("a")
        let queued = await waitUntil { self.library.recording(id: "a")?.sync.remote?.stage == .queued }
        XCTAssertTrue(queued)
        recording = library.recording(id: "a")
        XCTAssertEqual(recording?.partialTranscript?.markdown, partsText, "the parts stay while it tries again")
        XCTAssertEqual(recording.map(sync.badge(for:)), .queued)
        XCTAssertEqual(mac.with { $0.offered }, ["a"])

        mac.with {
            $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .transcribed, detail: "3 transcript chunks")
            $0.whole["a"] = self.wholeText
        }
        let completed = await waitUntil { self.library.recording(id: "a")?.transcript != nil }
        XCTAssertTrue(completed)
        recording = library.recording(id: "a")
        XCTAssertEqual(recording?.transcript?.markdown, wholeText)
        XCTAssertNil(recording?.partialTranscript, "replaced by the whole transcript")
        XCTAssertEqual(recording.map(sync.badge(for:)), .transcribed)
    }

    /// Huske.app before partial transcripts: a failure is only a failure, and
    /// the phone does not ask for a transcript it would not get.
    func testAnOlderMacsFailureIsLeftAsItWas() async {
        let mac = PartsMac()
        mac.with {
            $0.offersParts = false
            $0.statuses["a"] = self.gaveUpWithParts("a")
            $0.parts["a"] = self.partsText
        }
        addQueued("a", on: mac)
        let sync = makeManager(mac)

        sync.syncNow(.manual)
        let failed = await waitUntil { self.library.recording(id: "a")?.sync.remote?.stage == .failed }
        XCTAssertTrue(failed)
        _ = await waitUntil { !sync.isRunning }

        let recording = library.recording(id: "a")
        XCTAssertNil(recording?.sync.remote?.partial)
        XCTAssertNil(recording?.partialTranscript)
        XCTAssertEqual(recording.map(sync.badge(for:)), .failed(reason: "chunk 2/3 failed: decode error"))
        XCTAssertEqual(mac.with { $0.transcriptRequests }, [], "nothing to fetch")
    }

    /// The Mac said there were parts and then had none (it was retried there
    /// in between): the phone asks once and does not loop.
    func testPartsThatVanishedAreAskedForOnce() async {
        let mac = PartsMac()
        mac.with { $0.statuses["a"] = self.gaveUpWithParts("a") }
        addQueued("a", on: mac)
        let sync = makeManager(mac)

        sync.syncNow(.manual)
        let asked = await waitUntil { mac.with { $0.transcriptRequests } == ["a"] }
        XCTAssertTrue(asked)
        _ = await waitUntil { !sync.isRunning }
        let connects = mac.with { $0.connects }
        sync.syncNow(.macAppeared)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(mac.with { $0.transcriptRequests }, ["a"])
        XCTAssertEqual(mac.with { $0.connects }, connects, "a failure without parts is not work")
        XCTAssertNil(library.recording(id: "a")?.partialTranscript)
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .failed)
    }

    // MARK: tried again on the Mac

    /// A recording the phone holds as given up on by the Mac.
    private func addGivenUp(_ id: String, on mac: PartsMac, detail: String = "decode failed") {
        addQueued(id, on: mac)
        library.update(id) {
            $0.sync.remote = RemoteSnapshot(stage: .failed, detail: detail, updatedAt: Date())
        }
    }

    /// "Try again" in Huske on the Mac used to leave the iPhone at "Couldn't
    /// transcribe" for good: a failure is final there, so it never asked
    /// again and never fetched the transcript the Mac now had.
    func testARecordingTriedAgainOnTheMacIsNoticedWhenTheAppComesBack() async {
        let mac = PartsMac()
        mac.with { $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .failed, detail: "decode failed") }
        addGivenUp("a", on: mac)
        let sync = makeManager(mac)
        // Tried again on the Mac, and this time it worked.
        mac.with {
            $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .transcribed, detail: "3 transcript chunks")
            $0.whole["a"] = self.wholeText
        }

        sync.scenePhaseChanged(isActive: true)
        let fetched = await waitUntil { self.library.recording(id: "a")?.transcript != nil }

        XCTAssertTrue(fetched, "the transcript the Mac now has reached the phone")
        XCTAssertEqual(library.recording(id: "a")?.transcript?.markdown, wholeText)
        XCTAssertEqual(library.recording(id: "a").map(sync.badge(for:)), .transcribed)
        XCTAssertEqual(mac.with { $0.offered }, [], "asked about, not offered: nobody tapped Retry here")
    }

    /// On a real iPhone the browse stops in the background, so coming back
    /// the Mac is not visible yet: the question waits for it to appear.
    func testTheQuestionWaitsForTheMacToAppear() async {
        let mac = PartsMac()
        mac.with {
            $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .transcribed)
            $0.whole["a"] = self.wholeText
        }
        addGivenUp("a", on: mac)
        let presence = FakePresence(reachable: false)
        let sync = makeManager(mac, presence: presence)

        sync.scenePhaseChanged(isActive: true)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(mac.with { $0.connects }, 0, "nothing to connect to yet")

        presence.set(true)
        let fetched = await waitUntil { self.library.recording(id: "a")?.transcript != nil }
        XCTAssertTrue(fetched)

        // The Mac coming and going later is not another visit.
        mac.with { $0.statuses["b"] = RemoteStatus(recordingID: "b", state: .failed, detail: "x") }
        addGivenUp("b", on: mac)
        _ = await waitUntil { !sync.isRunning }
        let connects = mac.with { $0.connects }
        presence.set(false)
        try? await Task.sleep(for: .milliseconds(100))
        presence.set(true)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(mac.with { $0.connects }, connects, "a failure is still not work by itself")
    }

    /// Still being worked on there: the phone goes back to waiting for it.
    func testARecordingBeingTriedAgainOnTheMacIsFollowedAgain() async {
        let mac = PartsMac()
        mac.with { $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .transcribing, detail: "Transcribing part 2 of 3") }
        addGivenUp("a", on: mac)
        let sync = makeManager(mac)

        sync.scenePhaseChanged(isActive: true)
        let following = await waitUntil { self.library.recording(id: "a")?.sync.remote?.stage == .transcribing }
        XCTAssertTrue(following)

        mac.with {
            $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .transcribed)
            $0.whole["a"] = self.wholeText
        }
        let fetched = await waitUntil { self.library.recording(id: "a")?.transcript != nil }
        XCTAssertTrue(fetched)
    }

    /// Nothing changed on the Mac: one question per visit, and the failure
    /// stays as it was. A Mac that has forgotten the recording is not sent it
    /// again behind the user's back either.
    func testAFailureThatStandsIsAskedAboutOncePerVisit() async {
        let mac = PartsMac()
        mac.with { $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .failed, detail: "decode failed") }
        addGivenUp("a", on: mac)
        addGivenUp("gone", on: mac)  // the Mac no longer knows this one
        let sync = makeManager(mac)

        sync.scenePhaseChanged(isActive: true)
        let asked = await waitUntil { mac.with { $0.statusRequests } == 1 && !sync.isRunning }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(asked)
        XCTAssertEqual(mac.with { $0.statusRequests }, 1, "once, not in a loop")
        XCTAssertEqual(mac.with { $0.connects }, 1)
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .failed)
        XCTAssertEqual(library.recording(id: "gone")?.sync.remote?.stage, .failed)
        XCTAssertNotNil(library.recording(id: "gone")?.sync.uploadedAt)
        XCTAssertEqual(mac.with { $0.offered }, [])

        // The Mac learned to hand over parts since: the next visit brings them.
        mac.with {
            $0.statuses["a"] = self.gaveUpWithParts("a")
            $0.parts["a"] = self.partsText
        }
        sync.scenePhaseChanged(isActive: true)
        let parts = await waitUntil { self.library.recording(id: "a")?.partialTranscript != nil }
        XCTAssertTrue(parts)
    }

    func testARetryThatFailsAgainWithMorePartsBringsThoseBack() async {
        let mac = PartsMac()
        mac.with {
            $0.statuses["a"] = self.gaveUpWithParts("a")
            $0.parts["a"] = self.partsText
            $0.requeuesFailedOnOffer = false  // it answers at once: failed again
        }
        addQueued("a", on: mac)
        let sync = makeManager(mac)
        sync.syncNow(.manual)
        _ = await waitUntil { self.library.recording(id: "a")?.partialTranscript != nil }
        _ = await waitUntil { !sync.isRunning }

        // The retry got one more part before giving up again.
        mac.with {
            $0.statuses["a"] = RemoteStatus(recordingID: "a", state: .failed, detail: "chunk 4/4 failed")
                .withPartialTranscript(done: 3, total: 4)
            $0.parts["a"] = self.wholeText
        }
        sync.retry("a")
        let updated = await waitUntil { self.library.recording(id: "a")?.partialTranscript?.partsDone == 3 }

        XCTAssertTrue(updated)
        XCTAssertEqual(library.recording(id: "a")?.partialTranscript?.markdown, wholeText)
        XCTAssertEqual(library.recording(id: "a").map(sync.badge(for:)), .partial(done: 3, total: 4))
    }
}
