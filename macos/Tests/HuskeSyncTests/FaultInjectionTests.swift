// What a bad network does to a sync, proven end to end: a real client and a
// real server over loopback TLS-PSK, with `FaultProxy` in between playing the
// network. Each test states the outcome a user depends on — the error the
// phone sees is the one that makes it retry, the retry resumes at the byte the
// Mac acknowledged, and the engine gets one verified copy.

import CryptoKit
import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

final class FaultInjectionTests: XCTestCase {
    private var mac: SyncHarness!
    private var proxy: FaultProxy!
    private var proxyPort: UInt16!
    private var phone: PairedMac!

    /// 1.5 MB = five full chunks and a short one.
    private let recordingBytes = 1_500_000
    /// Client → server bytes after which the proxy turns on a connection:
    /// two chunks (2 × 262 144, plus a few KB of TLS and headers) are through,
    /// the third is in flight.
    private let midUpload = 600_000
    private let twoChunks = Int64(2 * SyncConstants.chunkSize)

    override func setUp() async throws {
        mac = try await SyncHarness()
        // The faults below land between two particular chunks.
        mac.chunking = .fixed(SyncConstants.chunkSize)
        phone = try await mac.pairedPhone()
        proxy = try FaultProxy(targetPort: try await mac.port())
        proxyPort = try await proxy.waitForPort()
    }

    override func tearDown() async throws {
        proxy?.stop()
        mac?.tearDown()
    }

    /// Uploads through the proxy until the fault ends it. Returns how long
    /// that took, the error, and the last offset the phone saw acknowledged.
    /// `macHearsOfIt`: whether the fault is one the Mac's side learns about.
    private func uploadThroughFault(
        _ manifest: RecordingManifest, _ url: URL,
        requestTimeout: TimeInterval = SyncSession.requestTimeout, macHearsOfIt: Bool = true
    ) async throws -> (seconds: TimeInterval, error: SyncError?, acked: Int64) {
        let session = try await mac.client(phone, port: proxyPort, requestTimeout: requestTimeout)
            .connect(timeout: 5)
        let progress = ProgressLog()
        let disconnectsBefore = mac.disconnects
        let (seconds, result) = await outcome {
            try await session.upload(manifest: manifest, fileURL: url) { sent, total in
                progress.append(sent, total)
            }
        }
        if case .success(let status) = result {
            XCTFail("the upload got through the fault: \(status.state)")
        }
        // A request that failed in transit ends the session, so closing it
        // does not wait on a goodbye to a connection that is gone.
        XCTAssertTrue(session.connection.isClosed, "the failed session still counts as open")
        let (closing, _) = await outcome { await session.close() }
        XCTAssertLessThan(closing, 1, "close() waited on a dead connection")
        if macHearsOfIt {
            // The Mac has let go of the broken connection, so nothing of it
            // can still be writing when the retry asks where to resume.
            let mac = self.mac!
            let released = await eventually(5) { mac.disconnects > disconnectsBefore }
            XCTAssertTrue(released, "the Mac still holds the broken connection")
        }
        return (seconds, result.syncError, progress.values.last?.0 ?? -1)
    }

    /// A fresh connection (the network is fine again) finishes the upload.
    /// Returns the offset it resumed from.
    private func retry(_ manifest: RecordingManifest, _ url: URL) async throws -> Int64 {
        proxy.fault = .none
        let session = try await mac.client(phone, port: proxyPort).connect(timeout: 5)
        let progress = ProgressLog()
        let status = try await session.upload(manifest: manifest, fileURL: url) { sent, total in
            progress.append(sent, total)
        }
        await session.close()
        XCTAssertEqual(status.state, .queued)
        return progress.values.first?.0 ?? -1
    }

    // MARK: stall

    /// The link goes quiet mid-upload (Wi-Fi out of range, AWDL dropped): the
    /// phone gives up after its request timeout instead of hanging, and the
    /// next connection carries on from the last byte the Mac acknowledged —
    /// while the Mac, which was never told, still holds the dead one.
    func testAStallMidUploadTimesOutAndTheNextConnectResumesAtTheAckedByte() async throws {
        let (manifest, url, data) = try mac.recording(bytes: recordingBytes)
        proxy.fault = .stall(afterUpBytes: midUpload)
        let disconnectsBefore = mac.disconnects

        let stalled = try await uploadThroughFault(manifest, url, requestTimeout: 1, macHearsOfIt: false)
        XCTAssertEqual(stalled.error, .timeout)
        XCTAssertGreaterThan(stalled.seconds, 0.9)
        XCTAssertLessThan(stalled.seconds, 5, "gave up after the request timeout, not later")
        XCTAssertEqual(stalled.acked, twoChunks)
        XCTAssertTrue(mac.delegate.received.isEmpty)

        // The Mac kept exactly what it acknowledged, and says so.
        XCTAssertEqual(mac.stagedBytes(manifest.id), data.prefix(Int(twoChunks)))
        let partial = await mac.server.statuses(for: [manifest.id])
        XCTAssertEqual(partial.first?.state, .receiving)
        XCTAssertEqual(mac.disconnects, disconnectsBefore, "nothing told the Mac; it still holds the connection")

        let resumedFrom = try await retry(manifest, url)
        XCTAssertEqual(resumedFrom, twoChunks, "resumed at the acked byte, not from 0")
        mac.assertCommittedOnce(manifest, data)
    }

    /// The Mac's half of that dead connection: no FIN ever arrives, so only
    /// its idle timeout (and, on a real network, TCP keepalive) can end it.
    func testAHalfOpenConnectionIsReapedByTheIdleTimeout() async throws {
        mac.server.idleTimeout = 0.4
        let (manifest, url, _) = try mac.recording(bytes: recordingBytes)
        proxy.fault = .stall(afterUpBytes: midUpload)
        let disconnectsBefore = mac.disconnects

        let session = try await mac.client(phone, port: proxyPort).connect(timeout: 5)
        let upload = Task { try await session.upload(manifest: manifest, fileURL: url) { _, _ in } }
        let mac = self.mac!
        let reaped = await eventually(5) { mac.disconnects > disconnectsBefore }
        XCTAssertTrue(reaped, "the Mac kept a connection that had gone silent")
        // What it had acknowledged is still staged for the retry.
        XCTAssertEqual(mac.stagedBytes(manifest.id)?.count, Int(twoChunks))
        upload.cancel()
        _ = await upload.result
        await session.close()
    }

    // MARK: unreachable

    /// Something accepts the TCP connection and never answers (a captive
    /// portal, a firewall that drops silently): a timeout, never a hang and
    /// never "the Mac refused this iPhone".
    func testABlackHoledConnectTimesOut() async throws {
        proxy.fault = .blackhole
        let client = try await mac.client(phone, port: proxyPort)
        let (seconds, result) = await outcome { try await client.connect(timeout: 1) }
        XCTAssertEqual(result.syncError, .timeout, "got \(result)")
        XCTAssertLessThan(seconds, 8)
    }

    /// Nothing listens on the port (Huske.app quit between the browse and the
    /// connect): fails at once, and not as a pairing problem.
    func testARefusedPortFailsAtOnceAsANetworkError() async throws {
        // A port that was just free: bind one, then let it go.
        let placeholder = try NWListener(using: .tcp)
        placeholder.newConnectionHandler = { $0.cancel() }
        placeholder.start(queue: DispatchQueue(label: "huske.test.placeholder"))
        var freed: UInt16 = 0
        for _ in 0..<200 where freed == 0 {
            freed = placeholder.port?.rawValue ?? 0
            if freed == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        placeholder.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)

        let client = try await mac.client(phone, port: freed)
        let (seconds, result) = await outcome { try await client.connect(timeout: 6) }
        // Its own case, not a string with a POSIX code in it: the app says
        // "open Huske on your Mac" for exactly this.
        XCTAssertEqual(result.syncError, .network(.refused), "a refused port should say so, got \(result)")
        XCTAssertLessThan(seconds, 3, "should not sit out the connect timeout")
    }

    // MARK: corruption

    /// One TLS record arrives damaged mid-upload. TLS refuses it, so nothing
    /// bad reaches the disk; the phone sees a dropped connection (retry), not
    /// a handshake failure (pair again), and the retry resumes.
    func testOneCorruptedRecordMidUploadDropsTheConnectionAndTheRetryResumes() async throws {
        let (manifest, url, data) = try mac.recording(bytes: recordingBytes)
        proxy.fault = .corruptRecord(afterUpBytes: midUpload)

        let broken = try await uploadThroughFault(manifest, url)
        XCTAssertEqual(proxy.corruptedRecords, 1)
        XCTAssertEqual(broken.error, .connectionClosed)
        XCTAssertLessThan(broken.seconds, 5, "noticed at once, not at the request timeout")
        XCTAssertEqual(broken.acked, twoChunks)
        XCTAssertTrue(mac.delegate.received.isEmpty)
        // Only bytes that passed TLS's integrity check were staged.
        XCTAssertEqual(mac.stagedBytes(manifest.id), data.prefix(Int(twoChunks)))

        let resumedFrom = try await retry(manifest, url)
        XCTAssertEqual(resumedFrom, twoChunks)
        mac.assertCommittedOnce(manifest, data)
    }

    // MARK: connection loss

    /// The TCP connection dies mid-upload with no TLS goodbye (the Mac's
    /// Wi-Fi toggled, a router rebooted).
    func testAnAbruptCloseMidUploadIsADroppedConnectionAndTheRetryResumes() async throws {
        let (manifest, url, data) = try mac.recording(bytes: recordingBytes)
        proxy.fault = .sever(afterUpBytes: midUpload)

        let cut = try await uploadThroughFault(manifest, url)
        XCTAssertEqual(cut.error, .connectionClosed)
        XCTAssertLessThan(cut.seconds, 5)
        XCTAssertEqual(cut.acked, twoChunks)
        XCTAssertEqual(mac.stagedBytes(manifest.id), data.prefix(Int(twoChunks)))

        let resumedFrom = try await retry(manifest, url)
        XCTAssertEqual(resumedFrom, twoChunks)
        mac.assertCommittedOnce(manifest, data)
    }

    /// The same, while the session was idle between requests: the next
    /// request fails at once instead of waiting out its timeout.
    func testAnAbruptCloseWhileIdleFailsTheNextRequestAtOnce() async throws {
        let session = try await mac.client(phone, port: proxyPort).connect(timeout: 5)
        _ = try await session.status(["a"])
        proxy.severAll()
        let (seconds, result) = await outcome { try await session.status(["a"]) }
        XCTAssertEqual(result.syncError, .connectionClosed, "got \(result)")
        XCTAssertLessThan(seconds, 5)
        await session.close()
    }

    /// Huske.app quits (or restarts its server) under an open session, then
    /// comes back: the phone sees a closed connection, and what the Mac had
    /// staged is still there to resume from.
    func testAServerStopClosesTheSessionAndARestartResumes() async throws {
        let (manifest, url, data) = try mac.recording(bytes: recordingBytes)
        // Straight to the server: its port changes when it restarts.
        let session = try await mac.client(phone).connect(timeout: 5)
        let connection = session.connection
        try await connection.send(.offer(OfferMessage(recording: manifest)))
        _ = try await connection.receive(timeout: 5)
        for index in 0..<2 {
            let offset = index * SyncConstants.chunkSize
            try await connection.send(
                .chunk(
                    ChunkMessage(recordingID: manifest.id, offset: Int64(offset)),
                    body: data.subdata(in: offset..<(offset + SyncConstants.chunkSize))))
            _ = try await connection.receive(timeout: 5)
        }

        mac.server.stop()
        let (seconds, result) = await outcome { try await session.status([manifest.id]) }
        XCTAssertEqual(result.syncError, .connectionClosed, "got \(result)")
        XCTAssertLessThan(seconds, 5, "noticed at once, not at the request timeout")
        await session.close()

        try mac.server.start()
        let again = try await mac.client(phone).connect(timeout: 5)
        let progress = ProgressLog()
        let status = try await again.upload(manifest: manifest, fileURL: url) { sent, total in
            progress.append(sent, total)
        }
        await again.close()
        XCTAssertEqual(progress.values.first?.0, twoChunks)
        XCTAssertEqual(status.state, .queued)
        mac.assertCommittedOnce(manifest, data)
    }

    // MARK: latency

    /// A slow link (25 ms each way — a congested or peer-to-peer hop) changes
    /// how long things take and nothing else.
    func testAddedLatencyOnlyMakesItSlower() async throws {
        proxy.latency = 0.025
        let (manifest, url, data) = try mac.recording(bytes: 3 * SyncConstants.chunkSize)
        let client = try await mac.client(phone, port: proxyPort)
        let (seconds, result) = await outcome { () -> RemoteStatus in
            let session = try await client.connect(timeout: 5)
            let status = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
            await session.close()
            return status
        }
        guard case .success(let status) = result else { return XCTFail("failed under latency: \(result)") }
        XCTAssertEqual(status.state, .queued)
        mac.assertCommittedOnce(manifest, data)
        // TLS handshake (2 round trips), hello, offer, 3 chunks, commit.
        XCTAssertGreaterThan(seconds, 8 * 2 * 0.025, "the delay was not applied")
    }
}
