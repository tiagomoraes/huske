// Transport and hand-off hardening: dead connections are noticed and dropped,
// a cancelled sync run lets go of its socket, pairing no longer takes the
// Bonjour advert down, and a recording is verified and handed to the engine
// exactly once without holding up other uploads.

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

// MARK: - dead and abandoned connections

final class ConnectionLifetimeTests: XCTestCase {
    private var mac: SyncHarness!

    override func setUp() async throws {
        mac = try await SyncHarness()
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    /// With only an idle time set, the probe interval and count stay at the
    /// system's 75 s × 8: a peer that vanished without a FIN (Wi-Fi dropped,
    /// the Mac slept) held the connection for about ten minutes.
    func testKeepaliveDropsAHalfOpenConnectionWithinAMinute() throws {
        let client = TLSPSK.clientParameters(identity: "device", key: Data(count: 32))
        let server = TLSPSK.serverParameters(
            keys: ["device": Data(count: 32)], queue: DispatchQueue(label: "huske.test.params")
        ) { _, _ in true }
        for (side, parameters) in [("client", client), ("server", server)] {
            let tcp = try XCTUnwrap(
                parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options, side)
            XCTAssertTrue(tcp.enableKeepalive, side)
            XCTAssertEqual(tcp.keepaliveIdle, 30, side)
            XCTAssertEqual(tcp.keepaliveInterval, 5, side)
            XCTAssertEqual(tcp.keepaliveCount, 4, side)
            XCTAssertLessThan(
                tcp.keepaliveIdle + tcp.keepaliveInterval * tcp.keepaliveCount, 60,
                "\(side): idle + interval × count is how long a dead peer is kept")
            XCTAssertTrue(tcp.noDelay, side)
        }
    }

    /// The Mac drops a connection that has asked nothing for the idle
    /// timeout (120 s in production); the phone's next request on it fails
    /// at once as a closed connection, which the app answers by reconnecting.
    func testASilentConnectionIsClosedAfterTheIdleTimeout() async throws {
        XCTAssertEqual(SyncServer.idleTimeout, 120)
        mac.server.idleTimeout = 0.3
        let phone = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(phone).connect(timeout: 5)

        let mac = self.mac!
        let dropped = await eventually(5) { mac.disconnects == 1 }
        XCTAssertTrue(dropped, "the idle connection was kept")

        let (seconds, result) = await outcome { try await session.status(["a"]) }
        XCTAssertEqual(result.syncError, .connectionClosed, "got \(result)")
        XCTAssertLessThan(seconds, 2)
        await session.close()

        // Nothing is lost by it: the phone just connects again.
        let again = try await mac.client(phone).connect(timeout: 5)
        _ = try await again.status(["a"])
        await again.close()
    }

    /// The idle clock restarts with every request: polling keeps a connection.
    func testAConnectionThatKeepsAskingIsNotClosed() async throws {
        mac.server.idleTimeout = 0.5
        let phone = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(phone).connect(timeout: 5)
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 200_000_000)
            _ = try await session.status(["a"])
        }
        XCTAssertEqual(mac.disconnects, 0, "1.2 s of polling, every gap shorter than the timeout")
        await session.close()
    }

    /// Network.framework receives ignore Task cancellation, so a cancelled
    /// sync run (the user forgot the Mac, background time ran out) used to
    /// sit in its pending request for the full 30 s timeout. Cancelling now
    /// closes the connection, which ends the request at once.
    func testCancellingARequestInFlightClosesTheConnectionAtOnce() async throws {
        let phone = try await mac.pairedPhone()
        let proxy = try FaultProxy(targetPort: try await mac.port())
        defer { proxy.stop() }
        proxy.fault = .stall(afterUpBytes: 600_000)
        let (manifest, url, _) = try mac.recording(bytes: 1_500_000)

        // Default 30 s request timeout: only cancellation can end this soon.
        let session = try await mac.client(
            phone, port: try await proxy.waitForPort(), chunking: .fixed(SyncConstants.chunkSize)
        ).connect(timeout: 5)
        let progress = ProgressLog()
        let upload = Task {
            try await session.upload(manifest: manifest, fileURL: url) { sent, total in
                progress.append(sent, total)
            }
        }
        // Two chunks acknowledged; the third is out and will never be answered.
        let twoChunks = Int64(2 * SyncConstants.chunkSize)
        let stuck = await eventually(5) { progress.values.last?.0 == twoChunks }
        XCTAssertTrue(stuck)
        try await Task.sleep(nanoseconds: 150_000_000)

        upload.cancel()
        let (seconds, result) = await outcome { try await upload.value }
        guard case .failure(let error) = result else { return XCTFail("the upload finished through a stalled link") }
        XCTAssertTrue(error is CancellationError, "got \(error)")
        XCTAssertLessThan(seconds, 2, "cancellation waited for the request timeout")
        XCTAssertTrue(session.connection.isClosed, "the cancelled run still holds its connection")

        // The session is over (a late reply could be mistaken for the next
        // request's), and says so immediately.
        let (after, next) = await outcome { try await session.status(["a"]) }
        XCTAssertNotNil(next.syncError, "got \(next)")
        XCTAssertLessThan(after, 2)
    }

    /// A task cancelled before it asks does not touch the connection: other
    /// users of the session are unaffected.
    func testARequestFromAnAlreadyCancelledTaskLeavesTheSessionAlone() async throws {
        let phone = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(phone).connect(timeout: 5)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.status(["a"])
        }
        let (_, result) = await outcome { try await cancelled.value }
        guard case .failure(let error) = result else { return XCTFail("a cancelled task got an answer") }
        XCTAssertTrue(error is CancellationError, "got \(error)")
        XCTAssertFalse(session.connection.isClosed)
        let items = try await session.status(["a"])
        XCTAssertEqual(items.first?.state, .unknown)
        await session.close()
    }
}

// MARK: - pairing without restarting the listener

final class ListenerStabilityTests: XCTestCase {
    private var mac: SyncHarness!

    override func setUp() async throws {
        mac = try await SyncHarness()
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    private func assertRejected(
        _ pairing: PairedMac, _ why: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let client = try await mac.client(pairing)
        let (_, result) = await outcome { () -> Void in
            let session = try await client.connect(timeout: 5)
            await session.close()
        }
        guard case .handshakeFailed? = result.syncError else {
            return XCTFail("\(why): expected a handshake failure, got \(result)", file: file, line: line)
        }
    }

    /// Every invite used to replace the listener, taking the Bonjour advert
    /// down for about a second — the phone saw its Mac vanish each time the
    /// pairing sheet opened. Invites now use slots the listener already has.
    func testInvitesDoNotReplaceTheListener() async throws {
        let epoch = mac.server.listenerEpoch
        let port = try await mac.port()
        var sessions: [SyncSession] = []
        for _ in 0..<3 {
            let pairing = PairedMac(invite: mac.server.makeInvite())
            XCTAssertEqual(mac.server.listenerEpoch, epoch, "an invite replaced the listener")
            sessions.append(try await mac.client(pairing, port: port).connect(timeout: 5))
        }
        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).count, 3)
        XCTAssertEqual(mac.server.port, port)
        XCTAssertEqual(
            mac.events.values.filter { if case .listening = $0 { return true } else { return false } }.count, 1,
            "the listener came up once and stayed")
        for session in sessions {
            _ = try await session.status(["a"])
            await session.close()
        }
    }

    /// Forgetting a device no longer replaces the listener either. Its key
    /// is still on the listener, so the refusal has to come from the
    /// handshake asking the registry.
    func testARemovedDeviceIsRefusedWithoutReplacingTheListener() async throws {
        let kept = try await mac.pairedPhone()
        let removed = try await mac.pairedPhone()
        let open = try await mac.client(removed).connect(timeout: 5)
        let epoch = mac.server.listenerEpoch

        mac.server.removeDevice(removed.deviceID)
        XCTAssertEqual(mac.server.listenerEpoch, epoch, "removing a device replaced the listener")

        // Its open connection is closed, and it cannot come back.
        let (_, stale) = await outcome { try await open.status(["a"]) }
        XCTAssertNotNil(stale.syncError, "the removed device kept its session: \(stale)")
        await open.close()
        try await assertRejected(removed, "a removed device")

        // Everyone else is untouched.
        let session = try await mac.client(kept).connect(timeout: 5)
        _ = try await session.status(["a"])
        await session.close()
    }

    /// An invite that expires while the listener carries its key is refused
    /// at the handshake, again without a restart.
    func testAnExpiredInviteIsRefusedWithoutReplacingTheListener() async throws {
        let invite = mac.server.makeInvite()
        let epoch = mac.server.listenerEpoch
        // The same slot, now past its expiry.
        mac.registry.addPending(
            PairingInvite(
                macID: invite.macID, macName: invite.macName, deviceID: invite.deviceID,
                key: invite.key, expiresAt: Date().addingTimeInterval(-1)))

        try await assertRejected(PairedMac(invite: invite), "an expired invite")
        XCTAssertEqual(mac.server.listenerEpoch, epoch)
        XCTAssertEqual(mac.registry.device(id: invite.deviceID)?.isPaired, false)
    }

    /// The spare slots are finite. When they run out the listener is replaced
    /// once, and every invite — those handed out before and the one that
    /// caused it — still pairs.
    func testRunningOutOfSpareSlotsReplacesTheListenerOnceAndLosesNoInvite() async throws {
        let epoch = mac.server.listenerEpoch
        var invites: [PairingInvite] = []
        for _ in 0..<SyncServer.spareSlots { invites.append(mac.server.makeInvite()) }
        XCTAssertEqual(mac.server.listenerEpoch, epoch, "the spare slots cover this many invites")

        invites.append(mac.server.makeInvite())
        XCTAssertEqual(mac.server.listenerEpoch, epoch + 1, "no slot left: the listener is replaced")
        XCTAssertEqual(Set(invites.map(\.deviceID)).count, invites.count)

        for invite in invites {
            let session = try await mac.client(PairedMac(invite: invite)).connect(timeout: 5)
            await session.close()
        }
        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).count, invites.count)

        // The new listener came with fresh spares.
        _ = mac.server.makeInvite()
        XCTAssertEqual(mac.server.listenerEpoch, epoch + 1)
    }

    /// What the phone actually watches: the Mac's Bonjour advert stays up
    /// through pairing and forgetting a device.
    func testTheBonjourAdvertDoesNotFlapWhenPairingOrForgetting() async throws {
        if ProcessInfo.processInfo.environment["HUSKE_SKIP_BONJOUR_TESTS"] == "1" {
            throw XCTSkip("HUSKE_SKIP_BONJOUR_TESTS=1")
        }
        let advertised = try await SyncHarness(advertise: true)
        defer { advertised.tearDown() }
        let monitor = MacPresenceMonitor(macID: advertised.registry.macID)
        monitor.start()
        defer { monitor.stop() }
        let seen = await eventually(10) { monitor.isReachable }
        XCTAssertTrue(seen, "the advertised server was never seen")

        let sightings = ReachabilityLog()
        let watching = Task {
            for await reachable in monitor.updates { sightings.append(reachable) }
        }
        defer { watching.cancel() }
        let primed = await eventually(2) { sightings.values == [true] }
        XCTAssertTrue(primed, "current value first: \(sightings.values)")

        var paired: [PairedMac] = []
        for _ in 0..<3 {
            let pairing = PairedMac(invite: advertised.server.makeInvite())
            let session = try await advertised.client(pairing).connect(timeout: 5)
            await session.close()
            paired.append(pairing)
        }
        advertised.server.removeDevice(paired[0].deviceID)

        // A replaced listener is gone from Bonjour for about a second; give a
        // flap twice that to show up.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(sightings.values, [true], "the Mac disappeared from Bonjour")
        XCTAssertTrue(monitor.isReachable)
    }
}

final class ReachabilityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { _values.append(value) } }
    var values: [Bool] { lock.withLock { _values } }
}

// MARK: - verify + hand off, once

final class HandOffTests: XCTestCase {
    private var mac: SyncHarness!
    private var receiver: GatedReceiver!

    override func setUp() async throws {
        receiver = GatedReceiver()
        mac = try await SyncHarness(receiver: receiver)
    }

    override func tearDown() async throws {
        receiver?.open()
        mac?.tearDown()
    }

    private var verifiedDirectory: URL {
        mac.server.stagingDirectory.appendingPathComponent("verified", isDirectory: true)
    }

    /// Puts a verified upload in staging as a commit leaves it.
    private func strandVerified(_ manifest: RecordingManifest, _ data: Data) throws {
        try data.write(to: verifiedDirectory.appendingPathComponent("\(manifest.id).m4a"))
        try WireJSON.encoder().encode(manifest)
            .write(to: verifiedDirectory.appendingPathComponent("\(manifest.id).manifest.json"))
    }

    /// Runs `redeliverVerified()` and says whether it came back by itself
    /// (it must not wait on, or join, a hand-off someone else is doing).
    private func redeliveryReturns() async -> Bool {
        let done = Outcome()
        let server = mac.server
        Task {
            await server.redeliverVerified()
            done.set("returned")
        }
        return await eventually(3) { done.value != nil }
    }

    /// `redeliverVerified()` running while a commit hands its recording to
    /// the engine used to give the delegate the same file a second time. The
    /// Mac's receiver replaces its destination before moving, so the second
    /// call could delete the audio the first had just moved.
    func testAReDeliveryLeavesARecordingBeingHandedOffAlone() async throws {
        let phone = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(phone).connect(timeout: 5)
        let (manifest, url, _) = try mac.recording(bytes: 300_000)
        let upload = Task { try await session.upload(manifest: manifest, fileURL: url) { _, _ in } }
        let receiver = self.receiver!
        let handingOff = await eventually(5) { receiver.handOffs == [manifest.id] }
        XCTAssertTrue(handingOff, "the commit never reached the delegate")

        // The verified file is on disk and the delegate has not returned.
        let returned = await redeliveryReturns()
        XCTAssertTrue(returned, "the re-delivery waited on the commit's hand-off")
        XCTAssertEqual(receiver.handOffs, [manifest.id], "handed to the delegate twice at once")

        receiver.open()
        let status = try await upload.value
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(receiver.handOffs, [manifest.id])
        await session.close()
    }

    /// Two re-deliveries at once (launch, then a manual retry) are one.
    func testTwoReDeliveriesAtOnceHandAVerifiedUploadOverOnce() async throws {
        let (manifest, _, data) = try mac.recording(bytes: 50_000)
        try strandVerified(manifest, data)

        let server = mac.server
        let first = Task { await server.redeliverVerified() }
        let receiver = self.receiver!
        let started = await eventually(5) { receiver.handOffs == [manifest.id] }
        XCTAssertTrue(started)

        let returned = await redeliveryReturns()
        XCTAssertTrue(returned)
        XCTAssertEqual(receiver.handOffs, [manifest.id])

        receiver.open()
        await first.value
        XCTAssertEqual(receiver.handOffs, [manifest.id])
        let left = try FileManager.default.contentsOfDirectory(atPath: verifiedDirectory.path)
        XCTAssertEqual(left, [], "the delegate took the file, so the record is dropped")

        // With the claim released a later pass works as before.
        try strandVerified(manifest, data)
        await server.redeliverVerified()
        XCTAssertEqual(receiver.handOffs, [manifest.id, manifest.id])
    }

    /// While a recording is being handed off the engine may not list it yet,
    /// and its file has left staging — the phone offering it again must still
    /// hear "skip", not "send it all again".
    func testAnOfferDuringAHandOffIsSkipped() async throws {
        let phone = PairedMac(invite: mac.server.makeInvite())
        let (manifest, _, data) = try mac.recording(bytes: 50_000)
        try strandVerified(manifest, data)
        let server = mac.server
        let redelivery = Task { await server.redeliverVerified() }
        let receiver = self.receiver!
        let started = await eventually(5) { receiver.handOffs == [manifest.id] }
        XCTAssertTrue(started)
        // As the Mac's receiver does mid-hand-off: the file is gone from
        // staging, the engine has not answered yet.
        try FileManager.default.removeItem(at: verifiedDirectory.appendingPathComponent("\(manifest.id).m4a"))

        let framed = try await mac.rawConnection(phone)
        defer { framed.cancel() }
        try await framed.send(
            .hello(HelloMessage(protocolVersion: 1, deviceID: phone.deviceID, deviceName: "p", deviceModel: "m", appVersion: "1")))
        _ = try await framed.receive(timeout: 5)
        try await framed.send(.offer(OfferMessage(recording: manifest)))
        guard case .offerReply(let reply)? = try await framed.receive(timeout: 5) else {
            return XCTFail("no offerReply")
        }
        XCTAssertEqual(reply.action, .skip)
        XCTAssertEqual(reply.offset, manifest.byteCount)

        receiver.open()
        await redelivery.value
        XCTAssertEqual(receiver.handOffs, [manifest.id])
    }

    /// A commit for a recording that is already on its way to the engine is
    /// acknowledged, not handed over a second time.
    func testACommitDuringAHandOffIsNotTakenTwice() async throws {
        let phone = PairedMac(invite: mac.server.makeInvite())
        let (manifest, _, data) = try mac.recording(bytes: 50_000)

        // The phone uploads everything but has not committed yet…
        let framed = try await mac.rawConnection(phone)
        defer { framed.cancel() }
        try await framed.send(
            .hello(HelloMessage(protocolVersion: 1, deviceID: phone.deviceID, deviceName: "p", deviceModel: "m", appVersion: "1")))
        _ = try await framed.receive(timeout: 5)
        try await framed.send(.offer(OfferMessage(recording: manifest)))
        _ = try await framed.receive(timeout: 5)
        try await framed.send(.chunk(ChunkMessage(recordingID: manifest.id, offset: 0), body: data))
        guard case .chunkAck? = try await framed.receive(timeout: 5) else { return XCTFail("no chunkAck") }

        // …while a verified copy of the same recording starts its hand-off.
        try strandVerified(manifest, data)
        let server = mac.server
        let redelivery = Task { await server.redeliverVerified() }
        let receiver = self.receiver!
        let started = await eventually(5) { receiver.handOffs == [manifest.id] }
        XCTAssertTrue(started)

        try await framed.send(.commit(CommitMessage(recordingID: manifest.id)))
        guard case .committed(let committed)? = try await framed.receive(timeout: 5) else {
            return XCTFail("the commit was not acknowledged")
        }
        XCTAssertEqual(committed.status.state, .received)
        XCTAssertEqual(receiver.handOffs, [manifest.id], "handed over twice")
        XCTAssertNil(mac.stagedBytes(manifest.id), "the spare copy was dropped")

        receiver.open()
        await redelivery.value
        XCTAssertEqual(receiver.handOffs, [manifest.id])
    }

    /// `commit` hashed the whole upload while holding the staging lock, which
    /// every other upload's offer, chunk and commit wait on: seconds of stall
    /// for a multi-GB recording. The hash now runs with the lock released.
    func testVerifyingOneUploadDoesNotHoldUpAnother() async throws {
        receiver.open()  // hand-offs are not what this test holds back
        let (slow, slowURL, _) = try mac.recording(bytes: 300_000)
        let (other, otherURL, _) = try mac.recording(bytes: 600_000)

        // Stretch the hash of `slow` for as long as the test wants.
        let hashing = Latch()
        mac.server.hashFile = { url in
            if url.lastPathComponent == "\(slow.id).part" { await hashing.wait() }
            return try await FileHashing.sha256Detached(of: url)
        }

        let phone = PairedMac(invite: mac.server.makeInvite())
        let first = try await mac.client(phone).connect(timeout: 5)
        let commit = Task { try await first.upload(manifest: slow, fileURL: slowURL) { _, _ in } }
        let verifying = await eventually(5) { hashing.arrivals == 1 }
        XCTAssertTrue(verifying, "the commit never started hashing")

        // A whole other upload — offer, chunks, commit — goes through meanwhile.
        let second = try await mac.client(phone).connect(timeout: 5)
        let (seconds, result) = await outcome {
            try await second.upload(manifest: other, fileURL: otherURL) { _, _ in }
        }
        guard case .success(let status) = result else { return XCTFail("the second upload failed: \(result)") }
        XCTAssertEqual(status.state, .queued)
        XCTAssertLessThan(seconds, 5)
        XCTAssertEqual(receiver.handOffs, [other.id], "finished while the first was still being verified")

        // The recording being verified is taken: offering it again is a skip…
        try await second.connection.send(.offer(OfferMessage(recording: slow)))
        guard case .offerReply(let reply)? = try await second.connection.receive(timeout: 5) else {
            return XCTFail("no offerReply")
        }
        XCTAssertEqual(reply.action, .skip)
        await second.close()

        // …and it completes untouched once the hash is done.
        hashing.open()
        let slowStatus = try await commit.value
        XCTAssertEqual(slowStatus.state, .queued)
        XCTAssertEqual(receiver.handOffs, [other.id, slow.id])
        await first.close()
    }

    /// The checksum still decides: a commit whose bytes do not hash to the
    /// manifest is discarded, and the claim it held is released.
    func testAChecksumMismatchStillDiscardsAndFreesTheRecording() async throws {
        receiver.open()
        let phone = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(phone).connect(timeout: 5)
        let (good, url, _) = try mac.recording(bytes: 300_000)
        let lying = RecordingManifest(
            id: good.id, title: good.title, startedAt: good.startedAt,
            durationSeconds: good.durationSeconds, byteCount: good.byteCount,
            sha256: String(repeating: "0", count: 64), fileExtension: good.fileExtension,
            contentType: good.contentType, sampleRate: good.sampleRate, channels: good.channels,
            timeZone: good.timeZone, deviceName: good.deviceName)
        let (_, result) = await outcome { try await session.upload(manifest: lying, fileURL: url) { _, _ in } }
        XCTAssertEqual(result.syncError, .checksumMismatch)
        XCTAssertNil(mac.stagedBytes(good.id))
        XCTAssertEqual(receiver.handOffs, [])

        let status = try await session.upload(manifest: good, fileURL: url) { _, _ in }
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(receiver.handOffs, [good.id])
        await session.close()
    }
}
