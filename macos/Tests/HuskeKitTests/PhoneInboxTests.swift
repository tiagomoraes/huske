import HuskeSync
import XCTest

@testable import HuskeKit

final class PhoneInboxTests: XCTestCase {
    private let manifest = RecordingManifest(
        id: "4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11",
        title: "Reunião com a Ana",
        startedAt: Date(timeIntervalSince1970: 1_763_571_780),
        durationSeconds: 1834.5,
        byteCount: 14_801_234,
        sha256: String(repeating: "0", count: 64),
        fileExtension: "m4a",
        contentType: "audio/mp4",
        sampleRate: 48_000,
        channels: 1,
        timeZone: "America/Sao_Paulo",
        deviceName: "iPhone de Tiago")

    func testInboxCapabilityIsProbed() {
        let help = """
            ╭─ Commands ───────────────╮
            │ run       Start a session │
            │ config    Inspect config  │
            │ devices   List inputs     │
            │ inbox     Phone + file    │
            ╰──────────────────────────╯
            """
        let caps = EngineCapabilities.parse(
            versionOutput: "huske 0.14.0", runHelp: "--control-socket", mainHelp: help)
        XCTAssertTrue(caps.inboxCLI)
        XCTAssertTrue(caps.isCurrent)
        let old = EngineCapabilities.parse(
            versionOutput: "huske 0.13.0", runHelp: "--control-socket",
            mainHelp: help.replacingOccurrences(of: "│ inbox     Phone + file    │\n", with: ""))
        XCTAssertFalse(old.inboxCLI)
        XCTAssertTrue(old.isCurrent, "inbox is optional: an engine without it still records")
    }

    func testAddArguments() {
        let args = PhoneInbox.addArguments(
            fileURL: URL(fileURLWithPath: "/tmp/stage/rec.m4a"), manifest: manifest)
        XCTAssertEqual(
            args,
            [
                "inbox", "add", "/tmp/stage/rec.m4a", "--move",
                "--id", "4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11",
                "--origin", "phone",
                "--title", "Reunião com a Ana",
                "--device", "iPhone de Tiago",
                "--started-at", "2025-11-19T14:03:00-03:00",
                "--duration", "1834.500",
                "--json",
            ])
    }

    func testParsesTheContractStatusExample() throws {
        let json = """
            {
              "id": "4E1C",
              "state": "processing",
              "updated_at": "2026-11-19T14:35:02-03:00",
              "attempts": 1,
              "chunks_total": 3,
              "chunks_done": 1,
              "session_id": "20261119T140300_5b0f7e4c",
              "transcripts": ["/Users/me/huske/transcripts/2026-11-19/140300_5b0f7e4c_001.md"],
              "error": null
            }
            """
        let item = try XCTUnwrap(PhoneInbox.parseStatus(Data(json.utf8)))
        XCTAssertEqual(item.state, .processing)
        XCTAssertEqual(item.chunksDone, 1)
        XCTAssertEqual(item.chunksTotal, 3)
        XCTAssertEqual(item.transcripts.count, 1)
        XCTAssertNil(item.error)
        XCTAssertEqual(item.updatedAt, WireDate.parse("2026-11-19T17:35:02Z"))

        let status = PhoneInbox.remoteStatus(for: item)
        XCTAssertEqual(status.state, .transcribing)
        XCTAssertEqual(status.progress ?? -1, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(status.detail, "Transcribing part 2 of 3")
    }

    func testStateMapping() {
        func map(_ state: String, attempts: Int = 0, transcripts: [String] = [], error: String? = nil) -> RemoteStatus {
            PhoneInbox.remoteStatus(
                for: InboxItemStatus(
                    id: "x", rawState: state, attempts: attempts, transcripts: transcripts, error: error))
        }
        XCTAssertEqual(map("queued").state, .queued)
        XCTAssertEqual(map("processing").state, .transcribing)
        XCTAssertNil(map("processing").progress, "no chunk counts yet → indeterminate")
        XCTAssertEqual(map("done", transcripts: ["a", "b"]).state, .transcribed)
        XCTAssertEqual(map("done", transcripts: ["a", "b"]).detail, "2 transcript chunks")
        XCTAssertEqual(map("done").detail, "No speech found")
        // Retryable failures stay non-terminal for the phone.
        XCTAssertEqual(map("failed", attempts: 1, error: "decode error").state, .queued)
        XCTAssertEqual(map("failed", attempts: 3, error: "decode error").state, .failed)
        XCTAssertEqual(map("failed", attempts: 3, error: "decode error").detail, "decode error")
    }

    func testParseAddOutput() {
        let ok = PhoneInbox.parseAddOutput(
            status: 0,
            stdout: #"{"id":"r1","title":"T","origin":"phone","state":"queued","attempts":0,"transcripts":[],"created":true}"#,
            stderr: "")
        guard case .added(let item, let created) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(item.id, "r1")
        XCTAssertEqual(item.title, "T")
        XCTAssertTrue(created)

        let again = PhoneInbox.parseAddOutput(
            status: 0, stdout: #"{"id":"r1","state":"done","transcripts":["/a.md"],"created":false}"#, stderr: "")
        guard case .added(let existing, false) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(existing.state, .done)

        // What the engine actually prints: indented JSON over many lines.
        let pretty = PhoneInbox.parseAddOutput(
            status: 0,
            stdout: """
                {
                  "id": "DEMO-1",
                  "title": "Demo",
                  "origin": "phone",
                  "state": "queued",
                  "attempts": 0,
                  "transcripts": [],
                  "error": null,
                  "created": true
                }

                """,
            stderr: "Fetching 4 files: 100%")
        guard case .added(let prettyItem, true) = pretty else { return XCTFail("\(pretty)") }
        XCTAssertEqual(prettyItem.id, "DEMO-1")
        XCTAssertEqual(prettyItem.state, .queued)

        XCTAssertEqual(
            PhoneInbox.parseAddOutput(status: 1, stdout: "{\n  \"error\": \"bad id\"\n}\n", stderr: ""),
            .failed("bad id"))
        XCTAssertEqual(
            PhoneInbox.parseAddOutput(status: 1, stdout: #"{"error": "unsupported audio"}"#, stderr: ""),
            .failed("unsupported audio"))
        XCTAssertEqual(
            PhoneInbox.parseAddOutput(status: 2, stdout: "", stderr: "Traceback (most recent call last):\n  boom"),
            .failed("Traceback (most recent call last):"))
    }

    func testFrontmatterIsStrippedAndChunksJoinInOrder() {
        let files = [
            "/a.md": "---\nsession_id: x\nchunk_seq: 1\n---\n\n[14:03:00] Olá, Ana.\n",
            "/b.md": "---\nchunk_seq: 2\n---\n[14:18:00] Tudo bem?\n",
            "/c.md": "No frontmatter here.",
        ]
        let text = PhoneInbox.joinedTranscript(paths: ["/a.md", "/b.md", "/missing.md", "/c.md"]) { files[$0] }
        XCTAssertEqual(text, "[14:03:00] Olá, Ana.\n\n[14:18:00] Tudo bem?\n\nNo frontmatter here.")
        XCTAssertEqual(PhoneInbox.joinedTranscript(paths: []) { _ in nil }, "")
        XCTAssertNil(PhoneInbox.joinedTranscript(paths: ["/gone.md"]) { _ in nil })
        XCTAssertEqual(PhoneInbox.stripFrontmatter("---\nonly: meta\n---"), "")
    }

    func testReadsStatusFromInboxRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let itemDir = root.appendingPathComponent("rec-1", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        let transcript = itemDir.appendingPathComponent("t.md")
        try "---\na: 1\n---\nhello".write(to: transcript, atomically: true, encoding: .utf8)
        try #"{"id":"rec-1","state":"done","transcripts":["\#(transcript.path)"]}"#
            .write(to: itemDir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)

        let item = try XCTUnwrap(PhoneInbox.readStatus(root: root, id: "rec-1"))
        XCTAssertEqual(PhoneInbox.transcript(for: item), "hello")
        XCTAssertNil(PhoneInbox.readStatus(root: root, id: "../rec-1"), "ids are validated")
        XCTAssertNil(PhoneInbox.readStatus(root: root, id: "nope"))
    }

    func testRootFromConfig() {
        XCTAssertEqual(PhoneInbox.root(fromConfigValue: nil), PhoneInbox.defaultRoot())
        XCTAssertEqual(
            PhoneInbox.root(fromConfigValue: "~/elsewhere/inbox").path,
            NSHomeDirectory() + "/elsewhere/inbox")
    }
}

final class PhoneInboxStagingRescueTests: XCTestCase {
    func testFindsAudioAnInterruptedAddLeftInStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("huske-inbox-\(UUID().uuidString)")
        let stage = root.appendingPathComponent(".staging/REC-9.k2j3h4", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data([1]).write(to: stage.appendingPathComponent("audio.m4a"))
        try Data([2]).write(to: stage.appendingPathComponent("recording.json"))
        XCTAssertEqual(PhoneInbox.stagedAudio(root: root, id: "REC-9")?.lastPathComponent, "audio.m4a")
        XCTAssertNil(PhoneInbox.stagedAudio(root: root, id: "REC-1"))
        XCTAssertNil(PhoneInbox.stagedAudio(root: root.appendingPathComponent("missing"), id: "REC-9"))
    }
}
