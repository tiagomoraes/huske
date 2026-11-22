// The support journal: bounded, persisted, readable as text.

import XCTest
@testable import Huske

@MainActor
final class SyncJournalTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sync-journal.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A clock that advances one second per reading, from a fixed start.
    private func tickingClock(from start: TimeInterval = 1_800_000_000) -> () -> Date {
        var tick = 0.0
        return {
            defer { tick += 1 }
            return Date(timeIntervalSince1970: start + tick)
        }
    }

    func testKeepsOnlyTheNewestEntries() {
        let journal = SyncJournal(capacity: 3, now: tickingClock())

        for index in 1...5 { journal.record(.run, "pass \(index)") }

        XCTAssertEqual(journal.entries.map(\.text), ["pass 3", "pass 4", "pass 5"])
    }

    func testTheDefaultCapacityIsAboutTwoHundred() {
        let journal = SyncJournal(now: tickingClock())

        for index in 1...450 { journal.record(.link, "event \(index)") }

        XCTAssertEqual(journal.entries.count, 200)
        XCTAssertEqual(journal.entries.first?.text, "event 251")
        XCTAssertEqual(journal.entries.last?.text, "event 450")
    }

    func testSurvivesARelaunch() {
        let first = SyncJournal(fileURL: fileURL, now: tickingClock())
        first.record(.link, "mac visible")
        first.record(.connect, "connected in 12 ms")
        first.flush()

        let second = SyncJournal(fileURL: fileURL, now: tickingClock(from: 1_800_000_100))
        XCTAssertEqual(second.entries, first.entries)

        second.record(.run, "finished")
        second.flush()
        XCTAssertEqual(SyncJournal(fileURL: fileURL).entries.map(\.text),
                       ["mac visible", "connected in 12 ms", "finished"])
    }

    func testAReloadedJournalIsTrimmedToTheCapacity() {
        let big = SyncJournal(fileURL: fileURL, capacity: 50, now: tickingClock())
        for index in 1...50 { big.record(.run, "pass \(index)") }
        big.flush()

        let small = SyncJournal(fileURL: fileURL, capacity: 10)

        XCTAssertEqual(small.entries.count, 10)
        XCTAssertEqual(small.entries.last?.text, "pass 50")
    }

    func testAnUnreadableFileStartsAnEmptyJournal() throws {
        try Data("not json".utf8).write(to: fileURL)

        let journal = SyncJournal(fileURL: fileURL, now: tickingClock())
        XCTAssertEqual(journal.entries, [])

        journal.record(.run, "still works")
        journal.flush()
        XCTAssertEqual(SyncJournal(fileURL: fileURL).entries.map(\.text), ["still works"])
    }

    func testReportIsPlainTextOldestFirst() {
        let journal = SyncJournal(now: tickingClock())
        journal.record(.link, "searching")
        journal.record(.connect, "failed: timeout")

        let report = journal.report(header: ["Huske for iPhone 1.0 (1)", "Link: Looking for your Mac…"])

        XCTAssertEqual(report, """
            Huske for iPhone 1.0 (1)
            Link: Looking for your Mac…

            Sync journal (oldest first, UTC):
            2027-01-15T08:00:00.000Z  link        searching
            2027-01-15T08:00:01.000Z  connect     failed: timeout
            """)
    }

    func testAnEmptyJournalSaysSo() {
        let report = SyncJournal().report(header: ["Huske for iPhone 1.0 (1)"])

        XCTAssertEqual(report, "Huske for iPhone 1.0 (1)\n\nNo sync activity recorded yet.")
    }

    func testRecordingsAreNamedByAShortID() {
        XCTAssertEqual(SyncJournal.shortID("4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11"), "4E1C0A5B")
        XCTAssertEqual(SyncJournal.shortID("abc"), "abc")
    }
}
