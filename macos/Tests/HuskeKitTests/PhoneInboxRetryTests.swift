import Foundation
import HuskeSync
import XCTest

@testable import HuskeKit

/// A phone recording the engine gave up on is `failed` — "terminal until
/// retried on the Mac" (sync-protocol.md). The phone's own Retry cannot revive
/// it (the Mac answers its re-offer with `skip`), so Huske.app must be able to
/// run `huske inbox retry` and read the answer.
final class PhoneInboxRetryTests: XCTestCase {
    func testRetryArguments() {
        XCTAssertEqual(
            PhoneInbox.retryArguments(id: "4E1C0A5B"), ["inbox", "retry", "4E1C0A5B", "--json"])
    }

    func testParseRetryOutput() {
        let retried = PhoneInbox.parseRetryOutput(
            id: "rec",
            status: 0,
            stdout: """
                {
                  "items": [
                    {"id": "rec", "state": "queued", "attempts": 0, "transcripts": [], "error": null,
                     "retried": true}
                  ]
                }
                """,
            stderr: "")
        guard case .retried(let item) = retried else { return XCTFail("\(retried)") }
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(PhoneInbox.remoteStatus(for: item).state, .queued)

        XCTAssertEqual(
            PhoneInbox.parseRetryOutput(
                id: "rec", status: 1,
                stdout: #"{"items": [{"id": "rec", "state": "failed", "attempts": 3, "retried": false, "error": "original audio is gone"}]}"#,
                stderr: ""),
            .refused("original audio is gone"))
        XCTAssertEqual(
            PhoneInbox.parseRetryOutput(
                id: "rec", status: 1,
                stdout: #"{"items": [{"id": "rec", "state": "unknown", "retried": false}]}"#, stderr: ""),
            .refused("The engine no longer has this recording"))
        XCTAssertEqual(
            PhoneInbox.parseRetryOutput(
                id: "rec", status: 1,
                stdout: #"{"items": [{"id": "rec", "state": "done", "transcripts": [], "retried": false}]}"#,
                stderr: ""),
            .refused("Not failed (done)"))
        XCTAssertEqual(
            PhoneInbox.parseRetryOutput(id: "rec", status: 1, stdout: #"{"error": "config: bad"}"#, stderr: ""),
            .refused("config: bad"))
        XCTAssertEqual(
            PhoneInbox.parseRetryOutput(id: "rec", status: 2, stdout: "", stderr: "Usage: huske inbox retry"),
            .refused("Usage: huske inbox retry"))
    }
}

/// The same round trip against the real engine CLI. Gated like the other
/// cross-language tests (CI runs `--filter PythonInterop`):
///
///   HUSKE_INTEROP_PYTHON=$PWD/../.venv/bin/python PYTHONPATH=$PWD/.. \
///     swift test --filter PhoneInboxPythonInterop
final class PhoneInboxPythonInteropTests: XCTestCase {
    func testFailedPhoneRecordingIsRetriedThroughTheRealCLI() throws {
        guard let python = ProcessInfo.processInfo.environment["HUSKE_INTEROP_PYTHON"] else {
            throw XCTSkip("set HUSKE_INTEROP_PYTHON to run the cross-language interop test")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("huske-retry-interop-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        try """
            inbox_root = "\(root.path)/inbox"
            output_root = "\(root.path)/transcripts"
            audio_root = "\(root.path)/audio"
            logs_root = "\(root.path)/logs"
            """.write(to: config, atomically: true, encoding: .utf8)
        // Not audio at all: decoding fails without ever loading a model.
        let upload = root.appendingPathComponent("upload.m4a")
        try Data("not an m4a".utf8).write(to: upload)

        func huske(_ args: [String]) throws -> (Int32, String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "huske"] + args + ["--config", config.path]
            var env = ProcessInfo.processInfo.environment
            env["HUSKE_NO_UPDATE_CHECK"] = "1"
            env["HOME"] = root.path  // never the developer's ~/huske
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus, String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self)
            )
        }

        let manifest = RecordingManifest(
            id: "RETRY-1", title: "Broken memo", startedAt: Date(timeIntervalSince1970: 1_763_571_780),
            durationSeconds: 3, byteCount: 10, sha256: String(repeating: "0", count: 64),
            fileExtension: "m4a", contentType: "audio/mp4", sampleRate: 48_000, channels: 1,
            timeZone: "America/Sao_Paulo", deviceName: "Interop iPhone")
        let (addStatus, addOut, addErr) = try huske(PhoneInbox.addArguments(fileURL: upload, manifest: manifest))
        guard case .added = PhoneInbox.parseAddOutput(status: addStatus, stdout: addOut, stderr: addErr) else {
            return XCTFail("inbox add: \(addOut) \(addErr)")
        }
        // Three one-shot passes spend the three attempts.
        for _ in 0..<PhoneInbox.maxAttempts {
            _ = try huske(["inbox", "process", "--json"])
        }
        let inbox = root.appendingPathComponent("inbox")
        let failed = try XCTUnwrap(PhoneInbox.readStatus(root: inbox, id: manifest.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(PhoneInbox.remoteStatus(for: failed).state, .failed, "terminal for the phone")

        let (status, out, err) = try huske(PhoneInbox.retryArguments(id: manifest.id))
        guard case .retried(let item) = PhoneInbox.parseRetryOutput(
            id: manifest.id, status: status, stdout: out, stderr: err)
        else { return XCTFail("inbox retry: \(status) \(out) \(err)") }
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.attempts, 0)
        XCTAssertEqual(PhoneInbox.readStatus(root: inbox, id: manifest.id)?.state, .queued)

        let (_, again, againErr) = try huske(PhoneInbox.retryArguments(id: manifest.id))
        XCTAssertEqual(
            PhoneInbox.parseRetryOutput(id: manifest.id, status: 1, stdout: again, stderr: againErr),
            .refused("Not failed (queued)"))
    }
}
