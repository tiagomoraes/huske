import XCTest
@testable import Huske

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recording(_ id: String, _ start: Date, title: String? = nil,
                           capture: CaptureState = .complete) -> Recording {
        Recording(id: id, title: title ?? "Recording \(id)", startedAt: start, duration: 60,
                  fileName: "\(id).m4a", capture: capture)
    }

    func testInsertSortsNewestFirstAndPersists() throws {
        let store = LibraryStore(rootDirectory: directory)
        let early = Date(timeIntervalSince1970: 1_000_000)
        store.insert(recording("a", early))
        store.insert(recording("b", early.addingTimeInterval(3600)))
        XCTAssertEqual(store.recordings.map(\.id), ["b", "a"])

        let reloaded = LibraryStore(rootDirectory: directory)
        XCTAssertEqual(reloaded.recordings.map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.recording(id: "a")?.startedAt, early)
    }

    func testUpdateRoundTripsNestedSyncState() throws {
        let store = LibraryStore(rootDirectory: directory)
        store.insert(recording("a", Date()))
        let when = Date(timeIntervalSince1970: 2_000_000)
        store.update("a") {
            $0.sync.macID = "mac-1"
            $0.sync.uploadedAt = when
            $0.sync.remote = RemoteSnapshot(stage: .transcribing, detail: "1/2", progress: 0.5, updatedAt: when)
            $0.transcript = TranscriptRecord(markdown: "[10:00:00 · mic] hi", fetchedAt: when)
        }
        let reloaded = LibraryStore(rootDirectory: directory)
        let copy = try XCTUnwrap(reloaded.recording(id: "a"))
        XCTAssertEqual(copy.sync.macID, "mac-1")
        XCTAssertEqual(copy.sync.remote?.stage, .transcribing)
        XCTAssertEqual(copy.sync.remote?.progress, 0.5)
        XCTAssertEqual(copy.transcript?.markdown, "[10:00:00 · mic] hi")
    }

    func testDeleteRemovesEntryAndAudioFile() throws {
        let store = LibraryStore(rootDirectory: directory)
        let entry = recording("a", Date())
        store.insert(entry)
        let audio = store.audioURL(for: entry)
        try Data("audio".utf8).write(to: audio)

        store.delete("a")

        XCTAssertNil(store.recording(id: "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(LibraryStore(rootDirectory: directory).recordings.isEmpty)
    }

    func testRenameTrimsAndIgnoresEmpty() {
        let store = LibraryStore(rootDirectory: directory)
        store.insert(recording("a", Date(), title: "Recording 14:03"))
        store.rename("a", to: "   Design   review \n")
        XCTAssertEqual(store.recording(id: "a")?.title, "Design review")
        store.rename("a", to: "   ")
        XCTAssertEqual(store.recording(id: "a")?.title, "Design review")
    }

    func testSectionsGroupByLocalDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 23, minute: 50)))
        let day2Early = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 0, minute: 10)))
        let day2Late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 14, minute: 3)))

        let sections = LibraryStore.group(
            [recording("a", day1), recording("b", day2Early), recording("c", day2Late)], calendar: calendar)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].recordings.map(\.id), ["c", "b"])
        XCTAssertEqual(sections[1].recordings.map(\.id), ["a"])
        XCTAssertEqual(sections[0].day, calendar.startOfDay(for: day2Late))
    }

    func testUnreadableIndexIsKeptAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("library.json")
        try Data("{not json".utf8).write(to: index)

        let store = LibraryStore(rootDirectory: directory)

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNotNil(store.loadError)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("library.unreadable-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testUnknownRemoteStageDecodesAsUnknown() throws {
        let json = #"{"stage":"teleporting","updatedAt":"2026-11-19T14:03:00Z"}"#
        let snapshot = try LibraryStore.decoder.decode(RemoteSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.stage, .unknown)
    }

    func testRecoveryFinalizesReadableAndMarksUnreadableDamaged() throws {
        let store = LibraryStore(rootDirectory: directory)
        store.insert(recording("good", Date(), capture: .inProgress))
        store.insert(recording("bad", Date().addingTimeInterval(-10), capture: .inProgress))
        store.insert(recording("done", Date().addingTimeInterval(-20), capture: .complete))

        let outcome = RecoveryScanner.reconcile(store) { url in
            url.lastPathComponent.hasPrefix("good") ? 42 : nil
        }

        XCTAssertEqual(outcome.recovered, ["good"])
        XCTAssertEqual(outcome.damaged, ["bad"])
        XCTAssertEqual(store.recording(id: "good")?.capture, .complete)
        XCTAssertEqual(store.recording(id: "good")?.duration, 42)
        XCTAssertNotNil(store.recording(id: "good")?.note)
        XCTAssertEqual(store.recording(id: "bad")?.capture, .damaged)
        XCTAssertEqual(store.recording(id: "done")?.capture, .complete)
        XCTAssertNil(store.recording(id: "done")?.note)
    }

    func testPipelinePredicates() {
        var r = recording("a", Date())
        XCTAssertTrue(r.needsUpload(to: "mac"))
        XCTAssertFalse(r.awaitsRemote(on: "mac"))

        r.sync.macID = "mac"
        r.sync.uploadedAt = Date()
        r.sync.remote = RemoteSnapshot(stage: .queued, updatedAt: Date())
        XCTAssertFalse(r.needsUpload(to: "mac"))
        XCTAssertTrue(r.needsUpload(to: "other-mac"), "a newly paired Mac needs its own copy")
        XCTAssertTrue(r.awaitsRemote(on: "mac"))

        r.sync.remote?.stage = .transcribed
        XCTAssertFalse(r.awaitsRemote(on: "mac"))
        XCTAssertTrue(r.needsTranscript(from: "mac"))

        r.transcript = TranscriptRecord(markdown: nil, fetchedAt: Date())
        XCTAssertFalse(r.needsTranscript(from: "mac"))
        XCTAssertFalse(r.needsUpload(to: "other-mac"), "transcribed recordings are never re-sent")

        var inProgress = recording("b", Date(), capture: .inProgress)
        XCTAssertFalse(inProgress.needsUpload(to: "mac"), "never upload a recording still in progress")
        inProgress.capture = .damaged
        XCTAssertFalse(inProgress.needsUpload(to: "mac"))
    }
}
