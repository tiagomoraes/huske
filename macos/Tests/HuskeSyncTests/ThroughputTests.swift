// Upload throughput on a link with latency, and the error split that tells
// the network from a local file.
//
// Uploads are stop-and-wait: one chunk, one acknowledgement. At a fixed
// 256 KiB that is a round trip per quarter megabyte, which on a link with
// 25 ms of latency each way costs more than the bytes do. The chunk size now
// follows the link (`UploadChunkSizer`), up to the 1 MiB frame limit.

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

final class UploadChunkSizerTests: XCTestCase {
    func testAFastLinkGrowsToTheFrameLimitAndStaysThere() {
        var sizer = UploadChunkSizer()
        XCTAssertEqual(sizer.size, 256 * 1024, "starts at the size every upload used before")
        var sizes: [Int] = []
        for _ in 0..<5 {
            sizer.record(bytes: sizer.size, seconds: 0.06)
            sizes.append(sizer.size)
        }
        XCTAssertEqual(sizes, [512 * 1024, 1_048_576, 1_048_576, 1_048_576, 1_048_576])
        XCTAssertEqual(sizer.size, SyncConstants.maxBodyLength, "never past what one frame may carry")
    }

    func testASlowLinkShrinksToTheFloor() {
        var sizer = UploadChunkSizer()
        var sizes: [Int] = []
        for _ in 0..<4 {
            sizer.record(bytes: sizer.size, seconds: 9)
            sizes.append(sizer.size)
        }
        XCTAssertEqual(sizes, [128 * 1024, 64 * 1024, 64 * 1024, 64 * 1024])
    }

    func testAMiddlingLinkKeepsItsSize() {
        var sizer = UploadChunkSizer()
        sizer.record(bytes: sizer.size, seconds: 2.5)
        XCTAssertEqual(sizer.size, SyncConstants.chunkSize)
        // Grown, then the link slows down: back off again.
        sizer.record(bytes: sizer.size, seconds: 0.1)
        sizer.record(bytes: sizer.size, seconds: 0.1)
        XCTAssertEqual(sizer.size, 1_048_576)
        sizer.record(bytes: sizer.size, seconds: 6)
        XCTAssertEqual(sizer.size, 512 * 1024)
    }

    /// The tail of a file is short however fast the link is: it must not
    /// count as a quick chunk, nor a slow one.
    func testAShortChunkSaysNothingAboutTheLink() {
        var sizer = UploadChunkSizer()
        sizer.record(bytes: 1_000, seconds: 0.001)
        XCTAssertEqual(sizer.size, SyncConstants.chunkSize)
        sizer.record(bytes: 1_000, seconds: 60)
        XCTAssertEqual(sizer.size, SyncConstants.chunkSize)
    }

    func testAFixedSizeNeverMoves() {
        var sizer = UploadChunkSizer(.fixed(100_000))
        sizer.record(bytes: 100_000, seconds: 0.001)
        sizer.record(bytes: 100_000, seconds: 60)
        XCTAssertEqual(sizer.size, 100_000)
        XCTAssertEqual(UploadChunkSizer(.fixed(50_000_000)).size, SyncConstants.maxBodyLength)
    }
}

final class ThroughputTests: XCTestCase {
    private var mac: SyncHarness!
    private var phone: PairedMac!
    private var proxy: FaultProxy!
    private var proxyPort: UInt16 = 0

    override func setUp() async throws {
        mac = try await SyncHarness()
        phone = try await mac.pairedPhone()
        proxy = try FaultProxy(targetPort: try await mac.port())
        proxyPort = try await proxy.waitForPort()
    }

    override func tearDown() async throws {
        proxy?.stop()
        mac?.tearDown()
    }

    /// One upload through the proxy. Returns how long it took and the chunk
    /// sizes it used (the steps of the acknowledged offset).
    private func upload(
        bytes: Int, chunking: UploadChunking
    ) async throws -> (seconds: TimeInterval, chunks: [Int64]) {
        let (manifest, url, data) = try mac.recording(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await mac.client(phone, port: proxyPort, chunking: chunking).connect(timeout: 5)
        let progress = ProgressLog()
        let started = Date()
        let status = try await session.upload(manifest: manifest, fileURL: url) { sent, total in
            progress.append(sent, total)
        }
        let seconds = Date().timeIntervalSince(started)
        await session.close()
        XCTAssertEqual(status.state, .queued)
        mac.assertCommittedOnce(manifest, data)
        let offsets = progress.values.map(\.0)
        return (seconds, zip(offsets.dropFirst(), offsets).map { $0 - $1 })
    }

    /// The largest chunk the client may send is exactly one frame body. Every
    /// version of the Mac has accepted that (the limit is the frame's, and
    /// was 1 MiB from the first commit), so no capability guards it.
    func testTheMacAcceptsAOneMebibyteChunk() async throws {
        let (manifest, _, data) = try mac.recording(bytes: SyncConstants.maxBodyLength + 5)
        let raw = try await mac.rawConnection(phone)
        defer { raw.cancel() }
        try await raw.send(
            .hello(
                HelloMessage(
                    protocolVersion: 1, deviceID: phone.deviceID, deviceName: "p", deviceModel: "m",
                    appVersion: "1")))
        _ = try await raw.receive(timeout: 5)
        try await raw.send(.offer(OfferMessage(recording: manifest)))
        _ = try await raw.receive(timeout: 5)
        try await raw.send(
            .chunk(
                ChunkMessage(recordingID: manifest.id, offset: 0),
                body: data.prefix(SyncConstants.maxBodyLength)))
        guard case .chunkAck(let ack)? = try await raw.receive(timeout: 10) else {
            return XCTFail("a 1 MiB chunk was not acknowledged")
        }
        XCTAssertEqual(ack.received, Int64(SyncConstants.maxBodyLength))
    }

    /// On a quick link an upload reaches 1 MiB chunks within two round trips.
    func testAnUploadGrowsItsChunksOnAQuickLink() async throws {
        let adaptive = try await upload(bytes: 6 * 1_048_576, chunking: .adaptive)
        XCTAssertEqual(
            adaptive.chunks,
            [262_144, 524_288, 1_048_576, 1_048_576, 1_048_576, 1_048_576, 1_048_576, 262_144])
        let fixed = try await upload(bytes: 6 * 1_048_576, chunking: .fixed(SyncConstants.chunkSize))
        XCTAssertEqual(fixed.chunks.count, 24)
        XCTAssertTrue(fixed.chunks.allSatisfy { $0 == 262_144 })
    }

    /// 25 ms each way — a congested or peer-to-peer hop. Each chunk costs a
    /// round trip, so fewer, larger chunks are what makes it quicker: a third
    /// of the round trips, and clearly less time.
    func testLargerChunksCutTheRoundTripsOnASlowLink() async throws {
        proxy.latency = 0.025
        let megabytes = 8
        let fixed = try await upload(bytes: megabytes * 1_048_576, chunking: .fixed(SyncConstants.chunkSize))
        let adaptive = try await upload(bytes: megabytes * 1_048_576, chunking: .adaptive)
        print(
            String(
                format: "[throughput] %d MiB at 25 ms each way — fixed 256 KiB: %d chunks, %.2f s · adaptive: %d chunks, %.2f s",
                megabytes, fixed.chunks.count, fixed.seconds, adaptive.chunks.count, adaptive.seconds))
        XCTAssertEqual(fixed.chunks.count, 32)
        XCTAssertEqual(adaptive.chunks.count, 10, "256 KiB, 512 KiB, then 1 MiB")
        // 32 round trips of ≥ 50 ms against 10: at least 1.1 s apart.
        XCTAssertLessThan(adaptive.seconds, fixed.seconds * 0.7, "larger chunks did not make it quicker")
    }

    /// The number the change is for: a two-hour recording (58 MB of AAC) over
    /// a link with 25 ms of latency each way. Slow by design, so it runs only
    /// when asked: HUSKE_SYNC_MEASURE=1 swift test --filter ThroughputTests.
    func testMeasureATwoHourRecordingOnASlowLink() async throws {
        guard ProcessInfo.processInfo.environment["HUSKE_SYNC_MEASURE"] == "1" else {
            throw XCTSkip("set HUSKE_SYNC_MEASURE=1 to measure")
        }
        let bytes = 58 * 1_000_000
        for latency in [0.0, 0.025] {
            proxy.latency = latency
            let fixed = try await upload(bytes: bytes, chunking: .fixed(SyncConstants.chunkSize))
            let adaptive = try await upload(bytes: bytes, chunking: .adaptive)
            print(
                String(
                    format: "[measure] 58 MB, %.0f ms each way — fixed 256 KiB: %d chunks, %.2f s · adaptive: %d chunks, %.2f s",
                    latency * 1000, fixed.chunks.count, fixed.seconds, adaptive.chunks.count, adaptive.seconds))
        }
    }
}

// MARK: - network or file?

final class NetworkFailureTests: XCTestCase {
    /// A refused connection is its own case — the app answers it with "open
    /// Huske on your Mac" — not a POSIX number in a string.
    func testPOSIXCodesBecomeNetworkFailures() {
        XCTAssertEqual(FramedConnection.map(.posix(.ECONNREFUSED)), .network(.refused))
        for code in [POSIXErrorCode.ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .EADDRNOTAVAIL] {
            guard case .network(.unreachable)? = Optional(FramedConnection.map(.posix(code))) else {
                return XCTFail("\(code) should read as no route")
            }
        }
        guard case .network(.other(let why)) = FramedConnection.map(.posix(.EPROTO)) else {
            return XCTFail("an unlisted code is still the network's")
        }
        XCTAssertEqual(why, "Protocol error, errno 100", "the system's words, not a bare number")
        guard case .network(.nameNotResolved) = FramedConnection.map(.dns(-65554)) else {
            return XCTFail("a DNS error is the network's")
        }
        // Unchanged: these already had cases of their own.
        XCTAssertEqual(FramedConnection.map(.posix(.ECONNRESET)), .connectionClosed)
        XCTAssertEqual(FramedConnection.map(.posix(.ETIMEDOUT)), .timeout)
        guard case .handshakeFailed = FramedConnection.map(.tls(-9806)) else {
            return XCTFail("a TLS error at connect is the key being refused")
        }
    }

    func testTheWordsNameTheWayOut() {
        XCTAssertEqual(
            SyncError.network(.refused).errorDescription,
            "The Mac isn't accepting connections. Open Huske on your Mac.")
        let unreachable = SyncError.network(NetworkFailure(posix: .EHOSTUNREACH)).errorDescription ?? ""
        XCTAssertTrue(unreachable.hasPrefix("Couldn't reach the Mac"), unreachable)
        XCTAssertFalse(unreachable.contains("61"))
    }

    /// The other half of the split: a recording that cannot be read is a
    /// local problem (`.io`), with the connection left usable for the next.
    func testAnUnreadableRecordingIsALocalErrorAndLeavesTheSessionUsable() async throws {
        let mac = try await SyncHarness()
        defer { mac.tearDown() }
        let phone = try await mac.pairedPhone()
        let (manifest, url, _) = try mac.recording(bytes: 300_000)
        let (other, otherURL, otherData) = try mac.recording(bytes: 10_000)
        try FileManager.default.removeItem(at: url)

        let session = try await mac.client(phone).connect(timeout: 5)
        let (_, result) = await outcome {
            try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        }
        guard case .io? = result.syncError else {
            return XCTFail("a missing file should be a local error, got \(result)")
        }
        let status = try await session.upload(manifest: other, fileURL: otherURL) { _, _ in }
        XCTAssertEqual(status.state, .queued)
        mac.assertCommittedOnce(other, otherData)
        await session.close()
    }

    /// A file cut short under the upload (still being written, damaged) is
    /// local too.
    func testAFileShorterThanItsManifestIsALocalError() async throws {
        let mac = try await SyncHarness()
        defer { mac.tearDown() }
        let phone = try await mac.pairedPhone()
        let (manifest, url, data) = try mac.recording(bytes: 300_000)
        try data.prefix(1_000).write(to: url)
        let session = try await mac.client(phone).connect(timeout: 5)
        let (_, result) = await outcome {
            try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        }
        guard case .io? = result.syncError else {
            return XCTFail("a short file should be a local error, got \(result)")
        }
        await session.close()
    }
}
