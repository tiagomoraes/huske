import Foundation
import XCTest

@testable import HuskeKit

final class CLIRunnerTests: XCTestCase {
    /// `huske inbox process --json` sends every child's output (the ASR
    /// subprocess, model-download progress bars) to stderr and prints its
    /// one JSON object on stdout only at the very end. Reading stdout to EOF
    /// before touching stderr deadlocked as soon as stderr passed the 64 KiB
    /// pipe buffer: the child blocked on write, the app blocked on read, until
    /// the 6-hour watchdog killed the transcription.
    func testLargeStderrBeforeStdoutDoesNotDeadlock() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\0' x >&2; echo '{\"ok\": true}'"
        let started = Date()
        let result = try await CLIRunner.run(
            binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 10)
        XCTAssertEqual(result.status, 0, "the watchdog killed a child blocked on a full stderr pipe")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), #"{"ok": true}"#)
        XCTAssertEqual(result.stderr.count, 300_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 9)
    }

    func testLargeStdoutAndStderrTogether() async throws {
        let script = "head -c 200000 /dev/zero | tr '\\0' e >&2; head -c 200000 /dev/zero | tr '\\0' o"
        let result = try await CLIRunner.run(
            binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }
}
