import Foundation
import XCTest

@testable import HuskeKit

final class SyncLogTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-synclog-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    func testLinesAreTimestampedAndAppended() throws {
        let stamp = Date(timeIntervalSince1970: 1_763_571_780)
        let log = SyncLog(fileURL: dir.appendingPathComponent("PhoneSync/sync.log"), now: { stamp })
        log.write("listening on port 51234")
        log.write("hello from iPhone de Teste (iPhone17,1, app 1.0)")
        log.flush()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" listening on port 51234"), lines[0])
        XCTAssertEqual(lines[0].prefix(19).count, 19)
        XCTAssertEqual(
            SyncLog.line("x", at: stamp, timeZone: TimeZone(identifier: "America/Sao_Paulo")!),
            "2025-11-19T14:03:00-03:00 x\n")
    }

    /// It holds pairing activity: private like the rest of PhoneSync.
    func testTheFileIsPrivate() throws {
        let log = SyncLog(fileURL: dir.appendingPathComponent("sync.log"))
        log.write("x")
        log.flush()
        let mode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let dirMode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(dirMode.intValue & 0o777, 0o700)
    }

    func testItRotatesAndStaysUnderTwiceTheCap() throws {
        let cap = 4 * 1024
        let log = SyncLog(fileURL: dir.appendingPathComponent("sync.log"), maxBytes: cap)
        for index in 0..<2_000 {
            log.write("event \(index) — offer 4E1C0A5B… 14801234 bytes — send from 0")
        }
        log.flush()
        XCTAssertLessThanOrEqual(size(log.fileURL), cap)
        XCTAssertLessThanOrEqual(size(log.previousURL), cap)
        XCTAssertGreaterThan(size(log.previousURL), 0, "never rotated")
        // Only the two files: nothing accumulates beside them.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["sync.log", "sync.log.1"])

        // The newest line is there; the tail is whole lines in order.
        let tail = log.tail()
        XCTAssertTrue(tail.hasSuffix("event 1999 — offer 4E1C0A5B… 14801234 bytes — send from 0\n"))
        let numbers = tail.split(separator: "\n").compactMap { line -> Int? in
            line.split(separator: " ").dropFirst(2).first.flatMap { Int($0) }
        }
        XCTAssertEqual(numbers, Array((numbers.first ?? 0)...1_999), "lines lost or out of order")
    }

    func testAReopenedLogKeepsAppendingAndCounting() throws {
        let url = dir.appendingPathComponent("sync.log")
        let cap = 2 * 1024
        let first = SyncLog(fileURL: url, maxBytes: cap)
        for index in 0..<20 { first.write("before relaunch \(index)") }
        first.flush()
        let sizeBefore = size(url)

        let second = SyncLog(fileURL: url, maxBytes: cap)
        second.write("after relaunch")
        second.flush()
        XCTAssertGreaterThan(size(url), sizeBefore, "a new launch must append, not start over")
        for index in 0..<200 { second.write("after relaunch \(index)") }
        second.flush()
        XCTAssertLessThanOrEqual(size(url), cap, "the size from before the relaunch was not counted")
    }

    func testTheTailIsCutAtALineBoundary() {
        let log = SyncLog(fileURL: dir.appendingPathComponent("sync.log"))
        for index in 0..<300 { log.write("line \(index) " + String(repeating: "x", count: 40)) }
        let tail = log.tail(maxBytes: 2_000)
        XCTAssertLessThanOrEqual(tail.utf8.count, 2_000)
        let lines = tail.split(separator: "\n")
        XCTAssertTrue(lines.allSatisfy { $0.contains(" line ") }, "a partial first line survived")
        XCTAssertTrue(lines.last?.contains("line 299 ") ?? false)
    }

    func testAnEmptyLogHasAnEmptyTail() {
        XCTAssertEqual(SyncLog(fileURL: dir.appendingPathComponent("sync.log")).tail(), "")
    }

    func testAMessageCannotSmuggleInLinesOrGrowWithoutBound() {
        let stamp = Date(timeIntervalSince1970: 0)
        let line = SyncLog.line("first\nsecond\r\nthird", at: stamp, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "1970-01-01T00:00:00Z first second third\n")
        let long = SyncLog.line(String(repeating: "é", count: 5_000), at: stamp)
        XCTAssertLessThanOrEqual(long.count, SyncLog.maxLineLength + 40)
        XCTAssertTrue(long.hasSuffix("…\n"))
    }

    func testWritesFromManyThreadsAllLand() {
        let log = SyncLog(fileURL: dir.appendingPathComponent("sync.log"))
        DispatchQueue.concurrentPerform(iterations: 200) { index in log.write("concurrent \(index)") }
        log.flush()
        XCTAssertEqual(log.tail().split(separator: "\n").count, 200)
    }
}
