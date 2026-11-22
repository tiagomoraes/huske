// Narrated end-to-end demo of the phone → Mac path, opt-in:
//
//   HUSKE_SYNC_DEMO=1 swift test --filter PhoneSyncDemo
//   HUSKE_SYNC_DEMO=1 HUSKE_DEMO_ENGINE=/abs/path/to/huske swift test --filter PhoneSyncDemo
//
// Real SyncServer advertised on Bonjour, real SyncClient resolving it by TXT
// `mac`, TLS-PSK pairing from the QR link, an upload interrupted mid-way and
// resumed, an idempotent re-offer, then status polling and the transcript.
// With HUSKE_DEMO_ENGINE the server's delegate hands the file to that engine
// exactly as Huske.app does (`huske inbox add … --move`, then `huske inbox
// process`), against a throwaway config so nothing touches ~/huske.

import Foundation
import Network
import XCTest

@testable import HuskeKit
@_spi(Testing) @testable import HuskeSync

private func say(_ text: String) {
    print("demo │ \(text)")
}

/// The app's hand-off, minus the UI: PhoneInbox + CLIRunner.
private final class EngineInboxDelegate: SyncServerDelegate, @unchecked Sendable {
    let engine: URL?
    let configPath: String
    let inboxRoot: URL
    private let lock = NSLock()
    private var processing: Task<Void, Never>?
    private var fakeStatuses: [String: RemoteStatus] = [:]

    init(engine: URL?, configPath: String, inboxRoot: URL) {
        self.engine = engine
        self.configPath = configPath
        self.inboxRoot = inboxRoot
    }

    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        guard let engine else {
            say("delegate: received \(manifest.id.prefix(8))… from \(device.name ?? "?") (no engine; fake queue)")
            try? FileManager.default.removeItem(at: fileURL)
            let status = RemoteStatus(recordingID: manifest.id, state: .transcribed, detail: "fake")
            lock.withLock { fakeStatuses[manifest.id] = status }
            return status
        }
        let args = PhoneInbox.addArguments(fileURL: fileURL, manifest: manifest) + ["--config", configPath]
        say("delegate: huske \(args.prefix(3).joined(separator: " ")) … --origin phone --json")
        let outcome: PhoneInbox.AddOutcome
        do {
            let result = try await CLIRunner.run(binary: engine, arguments: args, timeout: 120)
            outcome = PhoneInbox.parseAddOutput(status: result.status, stdout: result.stdout, stderr: result.stderr)
        } catch {
            outcome = .failed("\(error)")
        }
        switch outcome {
        case .added(let item, let created):
            say("delegate: inbox item \(item.id.prefix(8))… state=\(item.rawState) created=\(created)")
            startProcessing(engine)
            return PhoneInbox.remoteStatus(for: item)
        case .failed(let message):
            say("delegate: inbox add FAILED: \(message)")
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: message)
        }
    }

    private func startProcessing(_ engine: URL) {
        lock.withLock {
            guard processing == nil else { return }
            let config = configPath
            processing = Task.detached {
                say("delegate: huske inbox process --json (background)")
                let result = try? await CLIRunner.run(
                    binary: engine, arguments: ["inbox", "process", "--json", "--config", config],
                    timeout: 900)
                let tail = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "launch failed"
                say("delegate: inbox process exited \(result?.status ?? -1): \(tail.prefix(240))")
            }
        }
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        recordingIDs.map { id in
            if let fake = lock.withLock({ fakeStatuses[id] }) { return fake }
            guard let item = PhoneInbox.readStatus(root: inboxRoot, id: id) else { return .unknown(id) }
            return PhoneInbox.remoteStatus(for: item)
        }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? {
        if lock.withLock({ fakeStatuses[recordingID] }) != nil {
            return "[00:00:00] (fake transcript — set HUSKE_DEMO_ENGINE for the real one)"
        }
        guard let item = PhoneInbox.readStatus(root: inboxRoot, id: recordingID) else { return nil }
        return PhoneInbox.transcript(for: item)
    }

    func syncServerDevicesChanged(_ server: SyncServer) {
        say("delegate: devices changed")
    }

    func syncServerEngineAvailable(_ server: SyncServer) -> Bool { engine != nil }
}

final class PhoneSyncDemoTests: XCTestCase {
    func testPhoneSyncDemo() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HUSKE_SYNC_DEMO"] == "1" else {
            throw XCTSkip("set HUSKE_SYNC_DEMO=1 to run the narrated demo")
        }
        let engine = env["HUSKE_DEMO_ENGINE"].map { URL(fileURLWithPath: $0) }
        let root = URL(
            fileURLWithPath: env["HUSKE_DEMO_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("huske-sync-demo").path,
            isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        try """
            inbox_root = "\(root.path)/inbox"
            output_root = "\(root.path)/transcripts"
            audio_root = "\(root.path)/audio"
            asr_engine = "whisper"
            model = "large-v3-turbo"
            language = "en"
            """.write(to: configURL, atomically: true, encoding: .utf8)
        say("workdir \(root.path)")
        say("engine  \(engine?.path ?? "none (fake delegate)")")

        // --- Mac side ---------------------------------------------------
        let registry = DeviceRegistry(fileURL: root.appendingPathComponent("PhoneSync/devices.json"))
        let server = SyncServer(
            registry: registry, stagingDirectory: root.appendingPathComponent("PhoneSync/staging"),
            macName: "Huske Demo Mac", serverVersion: "demo")
        let delegate = EngineInboxDelegate(
            engine: engine, configPath: configURL.path, inboxRoot: root.appendingPathComponent("inbox"))
        server.delegate = delegate
        server.logHandler = { print("mac  │ \($0)") }
        try server.start()
        defer { server.stop() }
        let port = await server.waitUntilReady()
        say("server listening on port \(port.map(String.init) ?? "?") as _huske-sync._tcp, TXT mac=\(registry.macID.prefix(8))…")

        // --- pairing ----------------------------------------------------
        let invite = server.makeInvite()
        _ = await server.waitUntilReady()
        let link = invite.url.absoluteString
        let redacted = link.replacingOccurrences(of: Base64URL.encode(invite.key), with: "<32-byte key>")
        say("QR / link: \(redacted)")
        let pasted = "Pair with my Mac: \(link) — thanks!"
        let parsed = try XCTUnwrap(PairingInvite(string: pasted))
        let pairing = PairedMac(invite: parsed)
        say("phone parsed the link from pasted text; device \(pairing.deviceID.prefix(8))… stored")

        // A spoken memo, AAC in .m4a like the iPhone records.
        let audio = root.appendingPathComponent("memo.m4a")
        let sayTool = Process()
        sayTool.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        sayTool.arguments = [
            "-o", audio.path, "--data-format=aac",
            "Hello from the iPhone. This memo was recorded on the phone, synced to the Mac "
                + "over an encrypted peer to peer link, and transcribed by huske on the Mac.",
        ]
        try sayTool.run()
        sayTool.waitUntilExit()
        // Pad with a second of silence-equivalent bytes? No — the file is the
        // recording; its size and hash are what the manifest promises.
        let manifest = try RecordingManifest.make(
            id: "DEMO-\(UUID().uuidString.prefix(8))", title: "Demo memo from the iPhone",
            startedAt: Date().addingTimeInterval(-60), durationSeconds: 9.5, fileURL: audio,
            sampleRate: 22_050, channels: 1, timeZone: .current, deviceName: "Demo iPhone")
        say("recording \(manifest.id): \(manifest.byteCount) bytes, sha256 \(manifest.sha256.prefix(12))…")

        let client = SyncClient(
            pairing: pairing, deviceName: "Demo iPhone", deviceModel: "iPhone17,1", appVersion: "1.0")
        let first = try await client.connect(timeout: 15)
        say("connected via Bonjour + TLS-PSK; welcome from \"\(first.welcome.macName)\" engineAvailable=\(first.welcome.engineAvailable)")
        say("registry: device paired = \(registry.device(id: pairing.deviceID)?.isPaired == true)")

        // --- interrupted upload -----------------------------------------
        let chunk = 4096  // small chunks so a short memo still has several
        try await first.connection.send(.offer(OfferMessage(recording: manifest)))
        guard case .offerReply(let offer)? = try await first.connection.receive(timeout: 5) else {
            return XCTFail("no offerReply")
        }
        say("offer → \(offer.action.rawValue) from offset \(offer.offset)")
        let data = try Data(contentsOf: audio)
        let cut = min(data.count / 2, 2 * chunk)
        var sent = 0
        while sent < cut {
            let end = min(sent + chunk, cut)
            try await first.connection.send(
                .chunk(ChunkMessage(recordingID: manifest.id, offset: Int64(sent)), body: data.subdata(in: sent..<end)))
            _ = try await first.connection.receive(timeout: 5)
            sent = end
        }
        first.connection.cancel()
        say("✂︎ connection dropped after \(sent) of \(data.count) bytes (phone walked away)")

        // --- resume -----------------------------------------------------
        let second = try await client.connect(timeout: 15)
        let resumedAt = ResumeProbe()
        let status = try await second.upload(manifest: manifest, fileURL: audio) { sentBytes, total in
            resumedAt.record(sentBytes)
            if sentBytes == total { say("upload progress \(sentBytes)/\(total) (100%)") }
        }
        say("reconnected; upload resumed at offset \(resumedAt.first ?? -1) → committed: \(status.state.rawValue) (\(status.detail ?? ""))")
        XCTAssertEqual(resumedAt.first, Int64(sent))

        let again = try await second.upload(manifest: manifest, fileURL: audio) { _, _ in }
        say("re-offer of the same recording → skip; status \(again.state.rawValue)")

        // --- status polling + transcript ---------------------------------
        let deadline = Date().addingTimeInterval(engine == nil ? 5 : 600)
        var last: RemoteState?
        var final: RemoteStatus?
        while Date() < deadline {
            let current = try await second.status([manifest.id])[0]
            if current.state != last {
                say("status: \(current.state.rawValue)\(current.progress.map { String(format: " %.0f%%", $0 * 100) } ?? "") — \(current.detail ?? "")")
                last = current.state
            }
            if current.state.isTerminal {
                final = current
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let done = try XCTUnwrap(final, "recording never reached a terminal state")
        XCTAssertEqual(done.state, .transcribed)
        let transcript = try await second.transcript(manifest.id)
        say("transcript (\(transcript?.count ?? 0) chars):")
        for line in (transcript ?? "<none>").split(separator: "\n", omittingEmptySubsequences: false) {
            print("     │ \(line)")
        }
        await second.close()
        say("done")
    }
}

private final class ResumeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _first: Int64?
    func record(_ value: Int64) { lock.withLock { if _first == nil { _first = value } } }
    var first: Int64? { lock.withLock { _first } }
}
