// Real SyncServer + real SyncClient in one process over loopback TLS-PSK.
// Most tests connect to 127.0.0.1:<port> through the @_spi(Testing) endpoint
// initializer; `testBonjourDiscovery` exercises the real browse path and can
// be skipped with HUSKE_SKIP_BONJOUR_TESTS=1 where mDNS is unavailable.

import CryptoKit
import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

final class FakeDelegate: SyncServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [(RecordingManifest, Data, String)] = []
    private var _statuses: [String: RemoteStatus] = [:]
    private var _transcripts: [String: String] = [:]
    private var _devicesChanged = 0
    var engineAvailable = true

    var received: [(RecordingManifest, Data, String)] { lock.withLock { _received } }
    var devicesChanged: Int { lock.withLock { _devicesChanged } }

    func setStatus(_ status: RemoteStatus) { lock.withLock { _statuses[status.recordingID] = status } }
    func setTranscript(_ text: String, for id: String) { lock.withLock { _transcripts[id] = text } }

    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        try? FileManager.default.removeItem(at: fileURL)  // take ownership
        let status = RemoteStatus(recordingID: manifest.id, state: .queued, detail: "in the inbox")
        lock.withLock {
            _received.append((manifest, data, device.deviceID))
            _statuses[manifest.id] = status
        }
        return status
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        lock.withLock { recordingIDs.map { _statuses[$0] ?? .unknown($0) } }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? {
        lock.withLock { _transcripts[recordingID] }
    }

    func syncServerDevicesChanged(_ server: SyncServer) {
        lock.withLock { _devicesChanged += 1 }
    }

    func syncServerEngineAvailable(_ server: SyncServer) -> Bool { engineAvailable }
}

final class EndToEndTests: XCTestCase {
    private var dir: URL!
    private var server: SyncServer!
    private var registry: DeviceRegistry!
    private var delegate: FakeDelegate!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registry = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        server = SyncServer(
            registry: registry, stagingDirectory: dir.appendingPathComponent("staging"),
            macName: "Test Mac", serverVersion: "test")
        delegate = FakeDelegate()
        server.delegate = delegate
        server.advertisesService = false
        if ProcessInfo.processInfo.environment["HUSKE_SYNC_TEST_LOG"] == "1" {
            server.logHandler = { print("[server] \($0)") }
        }
        try server.start()
        let port = await server.waitUntilReady()
        XCTAssertNotNil(port)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private func currentPort() async throws -> UInt16 {
        let port = await server.waitUntilReady()
        return try XCTUnwrap(port, "listener not ready")
    }

    private func client(_ pairing: PairedMac, name: String = "iPhone de Teste") async throws -> SyncClient {
        let port = try await currentPort()
        return SyncClient(
            pairing: pairing, deviceName: name, deviceModel: "iPhone17,1", appVersion: "1.0",
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    private func pair(name: String = "iPhone de Teste") async throws -> (PairedMac, SyncSession) {
        let invite = server.makeInvite()
        let pairing = PairedMac(invite: invite)
        let session = try await client(pairing, name: name).connect(timeout: 5)
        return (pairing, session)
    }

    private func syntheticRecording(bytes count: Int, id: String = UUID().uuidString) throws -> (RecordingManifest, URL, Data) {
        var data = Data(count: count)
        for i in 0..<count { data[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 13) }
        let url = dir.appendingPathComponent("\(id).m4a")
        try data.write(to: url)
        let manifest = try RecordingManifest.make(
            id: id, title: "Synthetic", startedAt: Date(timeIntervalSince1970: 1_763_571_780),
            durationSeconds: 61, fileURL: url, sampleRate: 48_000, channels: 1,
            timeZone: TimeZone(identifier: "America/Sao_Paulo")!, deviceName: "iPhone de Teste")
        return (manifest, url, data)
    }

    // MARK: pairing

    func testPairingPromotesPendingToPaired() async throws {
        let invite = server.makeInvite()
        XCTAssertEqual(registry.device(id: invite.deviceID)?.isPaired, false)
        let session = try await client(PairedMac(invite: invite)).connect(timeout: 5)
        XCTAssertEqual(session.welcome.macID, registry.macID)
        XCTAssertEqual(session.welcome.macName, "Test Mac")
        XCTAssertEqual(session.welcome.protocolVersion, 1)
        XCTAssertTrue(session.welcome.engineAvailable)
        let device = try XCTUnwrap(registry.device(id: invite.deviceID))
        XCTAssertTrue(device.isPaired)
        XCTAssertEqual(device.name, "iPhone de Teste")
        XCTAssertEqual(device.model, "iPhone17,1")
        XCTAssertNotNil(device.lastSeenAt)
        XCTAssertGreaterThanOrEqual(delegate.devicesChanged, 1)
        await session.close()

        // Reconnecting as the now-paired device works and keeps it paired.
        let again = try await client(PairedMac(invite: invite), name: "Renamed").connect(timeout: 5)
        XCTAssertEqual(registry.device(id: invite.deviceID)?.name, "Renamed")
        await again.close()
    }

    func testTwoDevicesPairIndependently() async throws {
        let (_, a) = try await pair(name: "Phone A")
        let (_, b) = try await pair(name: "Phone B")
        XCTAssertEqual(Set(registry.devices().compactMap(\.name)), ["Phone A", "Phone B"])
        _ = try await a.status(["x"])  // the first session survived the listener restart
        await a.close()
        await b.close()
    }

    // MARK: rejection

    func testWrongKeyIsRejected() async throws {
        let invite = server.makeInvite()
        let forged = PairedMac(
            macID: invite.macID, macName: invite.macName, deviceID: invite.deviceID,
            key: Data(repeating: 1, count: 32), pairedAt: Date())
        do {
            let session = try await client(forged).connect(timeout: 5)
            await session.close()
            XCTFail("a wrong key must not get a welcome")
        } catch {
            guard case .handshakeFailed? = error as? SyncError else {
                return XCTFail("wrong key should be a handshake failure, got \(error)")
            }
        }
        XCTAssertEqual(registry.device(id: invite.deviceID)?.isPaired, false)
    }

    func testUnknownDeviceIsRejected() async throws {
        _ = server.makeInvite()  // the listener has *a* key, just not this one
        let stranger = PairedMac(
            macID: registry.macID, macName: "Test Mac", deviceID: UUID().uuidString,
            key: Data(repeating: 2, count: 32), pairedAt: Date())
        do {
            let session = try await client(stranger).connect(timeout: 5)
            await session.close()
            XCTFail("an unknown device must not get a welcome")
        } catch {
            guard case .handshakeFailed? = error as? SyncError else {
                return XCTFail("unknown device should be a handshake failure, got \(error)")
            }
        }
    }

    func testRemovedDeviceIsRejected() async throws {
        let (pairing, session) = try await pair()
        await session.close()
        server.removeDevice(pairing.deviceID)
        do {
            let again = try await client(pairing).connect(timeout: 5)
            await again.close()
            XCTFail("a removed device must not get a welcome")
        } catch {
            guard case .handshakeFailed? = error as? SyncError else {
                return XCTFail("removed device should be a handshake failure, got \(error)")
            }
        }
    }

    func testHelloMustMatchTheTLSIdentity() async throws {
        let (victim, victimSession) = try await pair(name: "Victim")
        await victimSession.close()
        let (attacker, attackerSession) = try await pair(name: "Attacker")
        await attackerSession.close()

        // Authenticate as the attacker, then claim to be the victim.
        let port = try await currentPort()
        let framed = FramedConnection(
            NWConnection(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                using: TLSPSK.clientParameters(identity: attacker.deviceID, key: attacker.key)),
            label: "spoof")
        try await framed.start(timeout: 5)
        try await framed.send(
            .hello(HelloMessage(protocolVersion: 1, deviceID: victim.deviceID, deviceName: "Spoof", deviceModel: "x", appVersion: "1")))
        let reply = try await framed.receive(timeout: 5)
        framed.cancel()
        guard case .error(let error) = reply else { return XCTFail("expected an error, got \(String(describing: reply))") }
        XCTAssertEqual(error.code, "bad_request")
        XCTAssertEqual(registry.device(id: victim.deviceID)?.name, "Victim")
    }

    func testRequestsBeforeHelloAreRefused() async throws {
        let invite = server.makeInvite()
        let port = try await currentPort()
        let framed = FramedConnection(
            NWConnection(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                using: TLSPSK.clientParameters(identity: invite.deviceID, key: invite.key)),
            label: "nohello")
        try await framed.start(timeout: 5)
        try await framed.send(.status(StatusRequestMessage(recordingIDs: ["a"])))
        let reply = try await framed.receive(timeout: 5)
        framed.cancel()
        guard case .error(let error) = reply else { return XCTFail("expected not_hello") }
        XCTAssertEqual(error.code, "not_hello")
    }

    // MARK: uploads

    func testUploadEndToEnd() async throws {
        let (pairing, session) = try await pair()
        let (manifest, url, data) = try syntheticRecording(bytes: 1_300_000)
        let seen = ProgressLog()
        let status = try await session.upload(manifest: manifest, fileURL: url) { sent, total in
            seen.append(sent, total)
        }
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.recordingID, manifest.id)
        XCTAssertEqual(seen.values.last?.0, Int64(data.count))
        XCTAssertEqual(seen.values.first?.0, 0)
        let received = try XCTUnwrap(delegate.received.first)
        XCTAssertEqual(received.0, manifest)
        XCTAssertEqual(received.1, data)
        XCTAssertEqual(received.2, pairing.deviceID)
        // Staging is clean once the delegate took the file.
        let staged = try FileManager.default.contentsOfDirectory(atPath: server.stagingDirectory.path)
        XCTAssertEqual(staged.filter { $0.hasSuffix(".part") }, [])
        await session.close()
    }

    func testEmptyRecordingUploads() async throws {
        let (_, session) = try await pair()
        let (manifest, url, _) = try syntheticRecording(bytes: 0)
        let status = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        XCTAssertEqual(status.state, .queued)
        await session.close()
    }

    func testResumeAfterMidTransferDisconnect() async throws {
        let (pairing, session) = try await pair()
        let (manifest, url, data) = try syntheticRecording(bytes: 1_000_000)

        // Send the offer and two chunks by hand, then drop the connection.
        let connection = session.connection
        try await connection.send(.offer(OfferMessage(recording: manifest)))
        guard case .offerReply(let offer)? = try await connection.receive(timeout: 5) else {
            return XCTFail("no offerReply")
        }
        XCTAssertEqual(offer.action, .send)
        XCTAssertEqual(offer.offset, 0)
        let chunk = SyncConstants.chunkSize
        for index in 0..<2 {
            let offset = index * chunk
            try await connection.send(
                .chunk(ChunkMessage(recordingID: manifest.id, offset: Int64(offset)), body: data.subdata(in: offset..<(offset + chunk))))
            guard case .chunkAck(let ack)? = try await connection.receive(timeout: 5) else {
                return XCTFail("no chunkAck")
            }
            XCTAssertEqual(ack.received, Int64(offset + chunk))
        }
        connection.cancel()

        // The Mac reports the partial upload.
        let observer = try await client(pairing).connect(timeout: 5)
        let partial = try await observer.status([manifest.id])
        XCTAssertEqual(partial.first?.state, .receiving)
        XCTAssertEqual(partial.first?.progress ?? 0, Double(2 * chunk) / 1_000_000, accuracy: 0.0001)

        // A fresh session resumes from where the bytes stopped.
        let seen = ProgressLog()
        let status = try await observer.upload(manifest: manifest, fileURL: url) { sent, total in
            seen.append(sent, total)
        }
        XCTAssertEqual(seen.values.first?.0, Int64(2 * chunk), "resumed at offset > 0")
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(delegate.received.count, 1)
        XCTAssertEqual(delegate.received.first?.1, data)
        await observer.close()
    }

    func testOffsetMismatchCarriesReceived() async throws {
        let (_, session) = try await pair()
        let (manifest, _, data) = try syntheticRecording(bytes: 10_000)
        let connection = session.connection
        try await connection.send(.offer(OfferMessage(recording: manifest)))
        _ = try await connection.receive(timeout: 5)
        try await connection.send(
            .chunk(ChunkMessage(recordingID: manifest.id, offset: 500), body: data.subdata(in: 500..<1000)))
        guard case .error(let error)? = try await connection.receive(timeout: 5) else {
            return XCTFail("expected offset_mismatch")
        }
        XCTAssertEqual(error.code, "offset_mismatch")
        XCTAssertEqual(error.received, 0)
        await session.close()
    }

    func testReofferOfAVerifiedRecordingIsSkipped() async throws {
        let (_, session) = try await pair()
        let (manifest, url, _) = try syntheticRecording(bytes: 300_000)
        _ = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        XCTAssertEqual(delegate.received.count, 1)

        // Raw offer: the Mac answers skip.
        try await session.connection.send(.offer(OfferMessage(recording: manifest)))
        guard case .offerReply(let reply)? = try await session.connection.receive(timeout: 5) else {
            return XCTFail("no offerReply")
        }
        XCTAssertEqual(reply.action, .skip)

        // And through the API: no second hand-off, status comes back.
        let status = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(delegate.received.count, 1, "never handed over twice")
        await session.close()
    }

    func testChecksumMismatchDiscardsAndRestarts() async throws {
        let (_, session) = try await pair()
        let (good, url, _) = try syntheticRecording(bytes: 400_000)
        let lying = RecordingManifest(
            id: good.id, title: good.title, startedAt: good.startedAt,
            durationSeconds: good.durationSeconds, byteCount: good.byteCount,
            sha256: String(repeating: "0", count: 64), fileExtension: good.fileExtension,
            contentType: good.contentType, sampleRate: good.sampleRate, channels: good.channels,
            timeZone: good.timeZone, deviceName: good.deviceName)
        do {
            _ = try await session.upload(manifest: lying, fileURL: url) { _, _ in }
            XCTFail("expected checksumMismatch")
        } catch {
            XCTAssertEqual(error as? SyncError, .checksumMismatch)
        }
        XCTAssertTrue(delegate.received.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: server.stagingDirectory.appendingPathComponent("\(good.id).part").path))

        // The session is still usable, and the honest manifest uploads from 0.
        let seen = ProgressLog()
        let status = try await session.upload(manifest: good, fileURL: url) { sent, total in
            seen.append(sent, total)
        }
        XCTAssertEqual(seen.values.first?.0, 0)
        XCTAssertEqual(status.state, .queued)
        await session.close()
    }

    func testPrematureCommitIsAChecksumMismatch() async throws {
        let (_, session) = try await pair()
        let (manifest, _, data) = try syntheticRecording(bytes: 50_000)
        let connection = session.connection
        try await connection.send(.offer(OfferMessage(recording: manifest)))
        _ = try await connection.receive(timeout: 5)
        try await connection.send(
            .chunk(ChunkMessage(recordingID: manifest.id, offset: 0), body: data.subdata(in: 0..<1000)))
        _ = try await connection.receive(timeout: 5)
        try await connection.send(.commit(CommitMessage(recordingID: manifest.id)))
        guard case .error(let error)? = try await connection.receive(timeout: 5) else {
            return XCTFail("expected checksum_mismatch")
        }
        XCTAssertEqual(error.code, "checksum_mismatch")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: server.stagingDirectory.appendingPathComponent("\(manifest.id).part").path))
        await session.close()
    }

    func testInvalidManifestIsABadRequest() async throws {
        let (_, session) = try await pair()
        let (good, url, _) = try syntheticRecording(bytes: 10)
        let bad = RecordingManifest(
            id: "../escape", title: "x", startedAt: good.startedAt, durationSeconds: 1,
            byteCount: good.byteCount, sha256: good.sha256, fileExtension: "m4a",
            contentType: "audio/mp4", sampleRate: 48_000, channels: 1, timeZone: "UTC",
            deviceName: "x")
        do {
            _ = try await session.upload(manifest: bad, fileURL: url) { _, _ in }
            XCTFail("expected bad_request")
        } catch SyncError.protocolError(let code, _) {
            XCTAssertEqual(code, "bad_request")
        }
        await session.close()
    }

    // MARK: status + transcript

    func testStatusAndTranscriptRoundTrip() async throws {
        let (_, session) = try await pair()
        delegate.setStatus(
            RemoteStatus(
                recordingID: "done-1", state: .transcribed, detail: "3 transcript chunks",
                updatedAt: Date(timeIntervalSince1970: 1_763_573_000), progress: 1))
        delegate.setStatus(RemoteStatus(recordingID: "busy-1", state: .transcribing, progress: 0.5))
        delegate.setTranscript("# Reunião\n\nOlá, Ana — tudo bem?\n", for: "done-1")

        let statuses = try await session.status(["done-1", "busy-1", "never-seen"])
        XCTAssertEqual(statuses.map(\.recordingID), ["done-1", "busy-1", "never-seen"])
        XCTAssertEqual(statuses.map(\.state), [.transcribed, .transcribing, .unknown])
        XCTAssertEqual(statuses[0].detail, "3 transcript chunks")
        XCTAssertEqual(statuses[0].updatedAt, Date(timeIntervalSince1970: 1_763_573_000))
        XCTAssertEqual(statuses[1].progress, 0.5)

        let transcript = try await session.transcript("done-1")
        XCTAssertEqual(transcript, "# Reunião\n\nOlá, Ana — tudo bem?\n")
        let missing = try await session.transcript("busy-1")
        XCTAssertNil(missing)
        await session.close()
    }

    func testConcurrentRequestsOnOneSessionAreSerialized() async throws {
        let (_, session) = try await pair()
        delegate.setStatus(RemoteStatus(recordingID: "a", state: .queued))
        try await withThrowingTaskGroup(of: [RemoteStatus].self) { group in
            for _ in 0..<8 {
                group.addTask { try await session.status(["a"]) }
            }
            for try await result in group {
                XCTAssertEqual(result.first?.state, .queued)
            }
        }
        await session.close()
    }

    // MARK: Bonjour

    func testBonjourDiscovery() async throws {
        if ProcessInfo.processInfo.environment["HUSKE_SKIP_BONJOUR_TESTS"] == "1" {
            throw XCTSkip("HUSKE_SKIP_BONJOUR_TESTS=1")
        }
        // A second, advertised server with its own identity so the browse has
        // exactly one TXT `mac` to match.
        let bonjourDir = dir.appendingPathComponent("bonjour", isDirectory: true)
        let bonjourRegistry = DeviceRegistry(fileURL: bonjourDir.appendingPathComponent("devices.json"))
        let advertised = SyncServer(
            registry: bonjourRegistry, stagingDirectory: bonjourDir.appendingPathComponent("staging"),
            macName: "Huske Test \(UUID().uuidString.prefix(6))", serverVersion: "test")
        advertised.delegate = delegate
        try advertised.start()
        defer { advertised.stop() }
        let invite = advertised.makeInvite()
        _ = await advertised.waitUntilReady()

        let monitor = MacPresenceMonitor(macID: bonjourRegistry.macID)
        monitor.start()
        defer { monitor.stop() }

        let pairing = PairedMac(invite: invite)
        let session = try await SyncClient(
            pairing: pairing, deviceName: "Bonjour Phone", deviceModel: "iPhone17,1", appVersion: "1.0"
        ).connect(timeout: 15)
        XCTAssertEqual(session.welcome.macID, bonjourRegistry.macID)
        XCTAssertEqual(bonjourRegistry.device(id: invite.deviceID)?.isPaired, true)
        await session.close()

        var reachable = false
        for await value in monitor.updates {
            if value {
                reachable = true
                break
            }
        }
        XCTAssertTrue(reachable)
        XCTAssertTrue(monitor.isReachable)
    }

    func testUnpairedMacIsNotFound() async throws {
        if ProcessInfo.processInfo.environment["HUSKE_SKIP_BONJOUR_TESTS"] == "1" {
            throw XCTSkip("HUSKE_SKIP_BONJOUR_TESTS=1")
        }
        let pairing = PairedMac(
            macID: UUID().uuidString, macName: "Nowhere", deviceID: UUID().uuidString,
            key: Data(count: 32), pairedAt: Date())
        do {
            _ = try await SyncClient(pairing: pairing, deviceName: "x", deviceModel: "x", appVersion: "1")
                .connect(timeout: 1.5)
            XCTFail("expected macNotFound")
        } catch {
            XCTAssertEqual(error as? SyncError, .macNotFound)
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [(Int64, Int64)] = []
    func append(_ sent: Int64, _ total: Int64) { lock.withLock { _values.append((sent, total)) } }
    var values: [(Int64, Int64)] { lock.withLock { _values } }
}
