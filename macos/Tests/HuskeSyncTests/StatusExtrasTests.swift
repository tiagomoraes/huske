// Partial transcripts and the structured "will retry" state
// (sync-protocol.md § RemoteStatus, § Versioning and capabilities).
//
// Both are additive and gated: `transcript.partial` and `status.retry` must
// be announced by the phone *and* the Mac. The iPhone app and Huske.app update
// separately, so every test here has its mixed-pair twin: a phone that does
// not announce the capability is sent exactly what it was sent before, and a
// phone talking to an older Mac behaves as it did.

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

/// A Mac whose engine gave up on "partial" with 2 of 3 parts transcribed, is
/// retrying "flaky", and finished "done".
private final class PartialDelegate: SyncServerDelegate, @unchecked Sendable {
    static let partialText = "[14:03:01 · mic] part one\n\n[14:33:10 · mic] part three"
    static let fullText = "[14:03:01 · mic] everything"
    static let updated = Date(timeIntervalSince1970: 1_763_571_780)

    private let lock = NSLock()
    private var _partialAsked: [String] = []
    var partialAsked: [String] { lock.withLock { _partialAsked } }

    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        try? FileManager.default.removeItem(at: fileURL)
        // Everything a real Mac may put on a status, to see what gets through.
        return RemoteStatus(recordingID: manifest.id, state: .received, detail: "Will retry: engine busy")
            .withRetry()
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        recordingIDs.map { id in
            switch id {
            case "partial":
                return RemoteStatus(
                    recordingID: id, state: .failed, detail: "chunk 2/3 failed: decode error",
                    updatedAt: Self.updated
                ).withPartialTranscript(done: 2, total: 3)
            case "flaky":
                return RemoteStatus(
                    recordingID: id, state: .queued, detail: "Will retry after an error: decode error",
                    updatedAt: Self.updated
                ).withRetry(attempt: 2, maxAttempts: 3)
            case "verbose":
                return RemoteStatus(
                    recordingID: id, state: .failed, detail: String(repeating: "é", count: 2000),
                    updatedAt: Self.updated
                ).withPartialTranscript(done: 1, total: 4)
            case "done":
                return RemoteStatus(
                    recordingID: id, state: .transcribed, detail: "3 transcript chunks",
                    updatedAt: Self.updated, progress: 1)
            default:
                return .unknown(id)
            }
        }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? {
        recordingID == "done" ? Self.fullText : nil
    }

    func syncServer(_ server: SyncServer, partialTranscriptFor recordingID: String) async -> String? {
        lock.withLock { _partialAsked.append(recordingID) }
        return ["partial", "verbose"].contains(recordingID) ? Self.partialText : nil
    }

    func syncServerDevicesChanged(_ server: SyncServer) {}
    func syncServerEngineAvailable(_ server: SyncServer) -> Bool { true }
}

/// The header of the next frame, as the JSON a peer would see.
private func headerJSON(_ message: WireMessage) throws -> [String: Any] {
    let frame = try WireCodec.encode(message)
    let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    let object = try JSONSerialization.jsonObject(with: frame.dropFirst(4).prefix(length))
    return try XCTUnwrap(object as? [String: Any])
}

final class StatusExtrasTests: XCTestCase {
    private var mac: SyncHarness!
    private var delegate: PartialDelegate!
    private var phone: PairedMac!

    override func setUp() async throws {
        delegate = PartialDelegate()
        mac = try await SyncHarness(receiver: delegate)
        phone = PairedMac(invite: mac.server.makeInvite())
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    private func session(announcing capabilities: [String] = SyncConstants.capabilities) async throws -> SyncSession {
        try await mac.client(phone, capabilities: capabilities).connect(timeout: 5)
    }

    /// A phone as it was before these capabilities: `hello` written by hand,
    /// then `request` as raw JSON; returns the reply's header as sent.
    private func oldPhone(asks request: String) async throws -> ([String: Any], Data) {
        let framed = try await mac.rawConnection(phone)
        defer { framed.cancel() }
        try await sendRawFrame(
            #"{"appVersion":"1.0 (1)","deviceID":"\#(phone.deviceID)","deviceModel":"iPhone16,1","deviceName":"iPhone","protocolVersion":1,"type":"hello"}"#,
            on: framed)
        guard case .welcome? = try await framed.receive(timeout: 5) else {
            XCTFail("no welcome")
            return ([:], Data())
        }
        try await sendRawFrame(request, on: framed)
        let received = try await framed.receive(timeout: 5)
        let reply = try XCTUnwrap(received)
        var body = Data()
        if case .transcriptReply(_, let data) = reply { body = data }
        return (try headerJSON(reply), body)
    }

    private func sendRawFrame(_ json: String, on framed: FramedConnection) async throws {
        let header = Data(json.utf8)
        var length = UInt32(header.count).bigEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + header
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            framed.connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    // MARK: both sides current

    func testThisBuildAnnouncesBothCapabilities() async throws {
        XCTAssertTrue(SyncConstants.capabilities.contains("transcript.partial"))
        XCTAssertTrue(SyncConstants.capabilities.contains("status.retry"))
        let session = try await session()
        XCTAssertTrue(session.supports(SyncCapability.partialTranscript))
        XCTAssertTrue(session.supports(SyncCapability.retryState))
        await session.close()
    }

    func testAPartialFailureIsAnnouncedAndItsTranscriptServed() async throws {
        let session = try await session()
        let statusReply = try await session.status(["partial"])
        let status = try XCTUnwrap(statusReply.first)
        XCTAssertEqual(status.state, .failed, "still a failure: Retry stays")
        XCTAssertEqual(status.detail, "chunk 2/3 failed: decode error")
        XCTAssertEqual(status.partial, true)
        XCTAssertEqual(status.partsDone, 2)
        XCTAssertEqual(status.partsTotal, 3)

        let fetched = try await session.fetchTranscript("partial")
        XCTAssertEqual(fetched, FetchedTranscript(text: PartialDelegate.partialText, isPartial: true))
        // The older call never passes a partial text off as a transcript.
        let whole = try await session.transcript("partial")
        XCTAssertNil(whole)
        await session.close()
    }

    func testAFinishedRecordingIsNeverMarkedPartial() async throws {
        let session = try await session()
        let statusReply = try await session.status(["done"])
        let status = try XCTUnwrap(statusReply.first)
        XCTAssertNil(status.partial)
        XCTAssertNil(status.partsDone)
        let fetched = try await session.fetchTranscript("done")
        XCTAssertEqual(fetched, FetchedTranscript(text: PartialDelegate.fullText, isPartial: false))
        XCTAssertEqual(delegate.partialAsked, [], "a whole transcript needs no second question")
        let unknown = try await session.fetchTranscript("nothing")
        XCTAssertNil(unknown)
        await session.close()
    }

    func testAnAutomaticRetryIsAnnouncedAsFields() async throws {
        let session = try await session()
        let statusReply = try await session.status(["flaky"])
        let status = try XCTUnwrap(statusReply.first)
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.retrying, true)
        XCTAssertEqual(status.attempt, 2)
        XCTAssertEqual(status.maxAttempts, 3)
        XCTAssertEqual(status.detail, "Will retry after an error: decode error", "the text stays for older phones")
        let doneReply = try await session.status(["done"])
        let done = try XCTUnwrap(doneReply.first)
        XCTAssertNil(done.retrying)
        XCTAssertNil(done.attempt)
        await session.close()
    }

    /// The clamp that keeps a status reply inside the frame rebuilds the
    /// status; it must not drop the extras on the way.
    func testALongDetailIsCutWithoutLosingTheExtras() async throws {
        let session = try await session()
        let statusReply = try await session.status(["verbose"])
        let status = try XCTUnwrap(statusReply.first)
        XCTAssertLessThanOrEqual(status.detail?.utf8.count ?? 0, 512)
        XCTAssertEqual(status.partial, true)
        XCTAssertEqual(status.partsDone, 1)
        XCTAssertEqual(status.partsTotal, 4)
        await session.close()
    }

    // MARK: an older phone with this Mac

    /// Exactly the keys v1 had: nothing new reaches a phone that did not ask.
    func testAPhoneWithoutTheCapabilitiesGetsTheStatusAsBefore() async throws {
        let (reply, _) = try await oldPhone(asks: #"{"type":"status","recordingIDs":["partial","flaky"]}"#)
        let items = try XCTUnwrap(reply["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            Set(items[0].keys), ["recordingID", "state", "detail", "updatedAt"],
            "failed, with its reason, and nothing else")
        XCTAssertEqual(items[0]["state"] as? String, "failed")
        XCTAssertEqual(items[0]["detail"] as? String, "chunk 2/3 failed: decode error")
        XCTAssertEqual(Set(items[1].keys), ["recordingID", "state", "detail", "updatedAt"])
        XCTAssertEqual(items[1]["state"] as? String, "queued")
        XCTAssertEqual(
            items[1]["detail"] as? String, "Will retry after an error: decode error",
            "the text an older phone recognises the state by")
    }

    func testAPhoneWithoutTheCapabilityIsNotServedAPartialTranscript() async throws {
        let (reply, body) = try await oldPhone(asks: #"{"type":"transcript","recordingID":"partial"}"#)
        XCTAssertEqual(reply["available"] as? Bool, false)
        XCTAssertNil(reply["partial"])
        XCTAssertEqual(body, Data())
        XCTAssertEqual(delegate.partialAsked, [], "not even asked for")
    }

    func testAPhoneWithoutTheCapabilityStillGetsWholeTranscripts() async throws {
        let (reply, body) = try await oldPhone(asks: #"{"type":"transcript","recordingID":"done"}"#)
        XCTAssertEqual(reply["available"] as? Bool, true)
        XCTAssertNil(reply["partial"], "a whole transcript's reply is byte for byte what it was")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), PartialDelegate.fullText)
    }

    /// Each capability gates only its own fields.
    func testEachCapabilityIsGatedOnItsOwn() async throws {
        let onlyRetry = try await session(announcing: [SyncCapability.retryState])
        var statuses = try await onlyRetry.status(["partial", "flaky"])
        XCTAssertNil(statuses[0].partial)
        XCTAssertNil(statuses[0].partsDone)
        XCTAssertEqual(statuses[1].retrying, true)
        let refused = try await onlyRetry.fetchTranscript("partial")
        XCTAssertNil(refused)
        await onlyRetry.close()

        let onlyPartial = try await session(announcing: [SyncCapability.partialTranscript])
        statuses = try await onlyPartial.status(["partial", "flaky"])
        XCTAssertEqual(statuses[0].partial, true)
        XCTAssertNil(statuses[1].retrying)
        XCTAssertNil(statuses[1].attempt)
        let served = try await onlyPartial.fetchTranscript("partial")
        XCTAssertEqual(served?.isPartial, true)
        await onlyPartial.close()
    }

    func testTheCommitAnswerIsGatedToo() async throws {
        let (manifest, url, _) = try mac.recording(bytes: 4096)
        let old = try await session(announcing: [])
        let plain = try await old.upload(manifest: manifest, fileURL: url) { _, _ in }
        XCTAssertEqual(plain.state, .received)
        XCTAssertEqual(plain.detail, "Will retry: engine busy")
        XCTAssertNil(plain.retrying)
        await old.close()

        let (second, secondURL, _) = try mac.recording(bytes: 4096)
        let current = try await session()
        let marked = try await current.upload(manifest: second, fileURL: secondURL) { _, _ in }
        XCTAssertEqual(marked.retrying, true)
        await current.close()
    }

    // MARK: this phone with an older Mac

    /// Huske.app before these capabilities: it announces neither, never marks
    /// anything partial and answers `transcript` for a failure with nothing.
    func testAnOlderMacBehavesAsBefore() async throws {
        mac.server.capabilities = []
        let session = try await session()
        XCTAssertFalse(session.supports(SyncCapability.partialTranscript))
        XCTAssertFalse(session.supports(SyncCapability.retryState))
        let statuses = try await session.status(["partial", "flaky"])
        XCTAssertEqual(statuses[0].state, .failed)
        XCTAssertNil(statuses[0].partial)
        XCTAssertEqual(statuses[1].state, .queued)
        XCTAssertNil(statuses[1].retrying)
        XCTAssertEqual(statuses[1].detail, "Will retry after an error: decode error")
        let fetched = try await session.fetchTranscript("partial")
        XCTAssertNil(fetched)
        let whole = try await session.transcript("done")
        XCTAssertEqual(whole, PartialDelegate.fullText)
        await session.close()
    }

    // MARK: on the wire

    func testTheExtrasAreAbsentFromTheWireUnlessSet() throws {
        let plain = try headerJSON(
            .statusReply(StatusReplyMessage(items: [RemoteStatus(recordingID: "r", state: .failed, detail: "why")])))
        let item = try XCTUnwrap((plain["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["recordingID", "state", "detail", "updatedAt"])

        let marked = try headerJSON(
            .statusReply(
                StatusReplyMessage(items: [
                    RemoteStatus(recordingID: "r", state: .failed).withPartialTranscript(done: 2, total: 3),
                    RemoteStatus(recordingID: "q", state: .queued).withRetry(attempt: 2, maxAttempts: 3),
                ])))
        let items = try XCTUnwrap(marked["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["partial"] as? Bool, true)
        XCTAssertEqual(items[0]["partsDone"] as? Int, 2)
        XCTAssertEqual(items[0]["partsTotal"] as? Int, 3)
        XCTAssertEqual(items[1]["retrying"] as? Bool, true)
        XCTAssertEqual(items[1]["attempt"] as? Int, 2)
        XCTAssertEqual(items[1]["maxAttempts"] as? Int, 3)

        let whole = try headerJSON(
            .transcriptReply(TranscriptReplyMessage(recordingID: "r", available: true), body: Data("x".utf8)))
        XCTAssertNil(whole["partial"])
        let part = try headerJSON(
            .transcriptReply(
                TranscriptReplyMessage(recordingID: "r", available: true, partial: true), body: Data("x".utf8)))
        XCTAssertEqual(part["partial"] as? Bool, true)
    }

    /// A status written before the extras existed decodes with none of them.
    func testAStatusWithoutTheExtrasDecodes() throws {
        let json = #"{"recordingID":"r","state":"failed","detail":"why","updatedAt":"2026-11-19T14:40:12-03:00"}"#
        let status = try WireJSON.decoder().decode(RemoteStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.state, .failed)
        XCTAssertNil(status.partial)
        XCTAssertNil(status.partsDone)
        XCTAssertNil(status.retrying)
        XCTAssertNil(status.maxAttempts)
    }

    func testLimitingNeverTouchesTheOriginalFields() {
        let full = RemoteStatus(
            recordingID: "r", state: .failed, detail: "why", updatedAt: PartialDelegate.updated, progress: 0.5
        ).withPartialTranscript(done: 2, total: 3).withRetry(attempt: 1, maxAttempts: 3)
        let bare = full.limited(to: [])
        XCTAssertEqual(
            bare,
            RemoteStatus(
                recordingID: "r", state: .failed, detail: "why", updatedAt: PartialDelegate.updated,
                progress: 0.5))
        XCTAssertEqual(full.limited(to: Set(SyncConstants.capabilities)), full)
    }
}
