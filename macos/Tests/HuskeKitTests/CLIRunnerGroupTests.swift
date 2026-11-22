import Foundation
import XCTest

@testable import HuskeKit

/// `huske inbox process` spawns an ASR worker. When the app's watchdog killed
/// the parent, the worker was orphaned, kept the inherited pipes open, and a
/// runner that read to EOF never returned — phone transcription stopped until
/// Huske was relaunched. These pin the runner's side of that: it returns when
/// the child exits, and a timeout takes the whole process group down.
final class CLIRunnerGroupTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitUntilGone(_ pid: pid_t, within timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isAlive(pid)
    }

    func testReturnsWhenTheChildExitsEvenIfAGrandchildHoldsThePipes() async throws {
        // The grandchild inherits stdout/stderr and outlives its parent.
        let started = Date()
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "sleep 6 & echo $!; echo done"], timeout: 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "waited for a pipe the child no longer owns")
        XCTAssertEqual(result.status, 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, "done")
        // A clean exit is not policed: what it left behind is its business.
        if let pid = lines.first.flatMap({ pid_t($0) }) { kill(pid, SIGKILL) }
    }

    func testATimeoutTakesTheWholeProcessGroupDown() async throws {
        // Parent waits on a child that would run for a minute: the shape of
        // `inbox process` and its worker.
        let started = Date()
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "sleep 60 & echo $!; wait"], timeout: 0.5, killGrace: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertNotEqual(result.status, 0)
        let pid = try XCTUnwrap(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let gone = await waitUntilGone(pid)
        XCTAssertTrue(gone, "the grandchild survived its parent's timeout")
    }

    func testAChildThatIgnoresSIGTERMIsKilledAfterTheGrace() async throws {
        let started = Date()
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "trap '' TERM; sleep 60 & echo $!; wait"],
            timeout: 0.3, killGrace: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 0.7, "SIGKILL came before the grace period")
        XCTAssertLessThan(elapsed, 5)
        XCTAssertEqual(result.status, SIGKILL)
        let pid = try XCTUnwrap(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let gone = await waitUntilGone(pid)
        XCTAssertTrue(gone, "the grandchild ignored SIGTERM and was left running")
    }

    /// Killed from outside (not by our watchdog): its workers still go.
    func testAChildKilledByASignalDoesNotLeaveItsGroupBehind() async throws {
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "sleep 60 & echo $!; kill -KILL $$"], timeout: 30)
        XCTAssertEqual(result.status, SIGKILL)
        let pid = try XCTUnwrap(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let gone = await waitUntilGone(pid)
        XCTAssertTrue(gone, "an orphan of a killed child kept running")
    }

    func testTheChildLeadsItsOwnProcessGroup() async throws {
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "echo $$; ps -o pgid= -p $$"], timeout: 10)
        let numbers = result.stdout.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(numbers.count, 2, result.stdout)
        XCTAssertEqual(numbers.first, numbers.last, "pgid should be the child's own pid")
        XCTAssertNotEqual(numbers.last, getpgrp(), "the child shares the app's process group")
    }

    func testExitCodesAndOutputArePassedThrough() async throws {
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
    }

    func testStandardInputIsEmptyAndTheUpdateCheckIsOff() async throws {
        let result = try await CLIRunner.run(
            binary: shell, arguments: ["-c", "cat; echo \"check=$HUSKE_NO_UPDATE_CHECK\""], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "check=1\n")
    }

    func testAMissingBinaryThrows() async {
        do {
            _ = try await CLIRunner.run(
                binary: URL(fileURLWithPath: "/nonexistent/huske"), arguments: ["--version"], timeout: 5)
            XCTFail("expected a launch error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("/nonexistent/huske"), error.localizedDescription)
        }
    }
}
