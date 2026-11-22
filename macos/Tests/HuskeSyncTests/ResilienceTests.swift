// Failure modes that made sync stall, churn or mislead: a listener or browser
// that died and never came back, a reply too big to frame, a TLS hiccup read
// as "unpaired", cancellation that was ignored, timeouts that never fired.
// Same style as EndToEndTests: a real server and client over loopback.

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

final class ResilienceTests: XCTestCase {
    private var dir: URL!
    private var server: SyncServer!
    private var registry: DeviceRegistry!
    private var delegate: FakeDelegate!
    private var events: EventLog!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-resilience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registry = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        server = SyncServer(
            registry: registry, stagingDirectory: dir.appendingPathComponent("staging"),
            macName: "Test Mac", serverVersion: "test")
        delegate = FakeDelegate()
        server.delegate = delegate
        server.advertisesService = false
        events = EventLog()
        let events = self.events!
        server.onEvent = { events.append($0) }
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

    private func client(_ pairing: PairedMac, port: UInt16? = nil) async throws -> SyncClient {
        let resolved: UInt16
        if let port { resolved = port } else { resolved = try await currentPort() }
        return SyncClient(
            pairing: pairing, deviceName: "iPhone de Teste", deviceModel: "iPhone17,1", appVersion: "1.0",
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: resolved)!))
    }

    private func pair() async throws -> (PairedMac, SyncSession) {
        let pairing = PairedMac(invite: server.makeInvite())
        let session = try await client(pairing).connect(timeout: 5)
        return (pairing, session)
    }

    private func syntheticRecording(bytes count: Int) throws -> (RecordingManifest, URL, Data) {
        let id = UUID().uuidString
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

    /// Polls `condition` until true or `timeout`.
    private func eventually(
        _ timeout: TimeInterval, _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    // MARK: listener

    /// A listener that fails at runtime used to stay down (`running` stayed
    /// true, so the app's start() was a no-op) until Huske was relaunched.
    func testListenerRestartsItselfAfterARuntimeFailure() async throws {
        _ = try await currentPort()
        server.simulateListenerState(.failed(.posix(.ENETDOWN)))
        XCTAssertNil(server.port)
        XCTAssertNotNil(server.lastError)
        XCTAssertTrue(events.values.contains { if case .listenerFailed = $0 { return true } else { return false } })

        let port = await server.waitUntilReady(timeout: 6)
        XCTAssertNotNil(port, "the listener never came back")
        XCTAssertNil(server.lastError)
        let failedAt = try XCTUnwrap(events.values.lastIndex { if case .listenerFailed = $0 { return true } else { return false } })
        XCTAssertTrue(
            events.values[failedAt...].contains { if case .listening = $0 { return true } else { return false } },
            "`.listening` is emitted again after the restart")

        // And a phone can pair and talk to it.
        let (_, session) = try await pair()
        _ = try await session.status(["x"])
        await session.close()
    }

    func testListenerRetryBacksOff() {
        XCTAssertEqual(
            (1...8).map { SyncServer.listenerRetryDelay(afterFailures: $0) }, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(
            (1...7).map { MacPresenceMonitor.retryDelay(afterFailures: $0) }, [1, 2, 4, 8, 16, 30, 30])
    }

    /// `.waiting` (e.g. Local Network access denied) used to be ignored: the
    /// Mac showed no error while nothing could reach it.
    func testListenerWaitingIsReportedAndClears() async throws {
        _ = try await currentPort()
        server.simulateListenerState(.waiting(.dns(DiscoveryIssue.policyDeniedCode)))
        XCTAssertEqual(server.lastError?.contains("Local Network"), true, server.lastError ?? "nil")
        XCTAssertTrue(events.values.contains { if case .listenerFailed = $0 { return true } else { return false } })

        server.simulateListenerState(.ready)
        XCTAssertNil(server.lastError)
        XCTAssertTrue(events.values.last.map { if case .listening = $0 { return true } else { return false } } ?? false)
    }

    // MARK: TLS after the handshake

    /// One damaged record mid-session used to surface as `handshakeFailed`,
    /// which the phone shows as "Pair again" — for a transient error.
    func testATLSErrorAfterTheHandshakeIsADroppedConnection() async throws {
        let invite = server.makeInvite()
        let proxy = try FaultProxy(targetPort: try await currentPort())
        defer { proxy.stop() }
        let proxyPort = try await proxy.waitForPort()
        let session = try await client(PairedMac(invite: invite), port: proxyPort).connect(timeout: 5)

        proxy.fault = .corruptReplyRecord
        do {
            _ = try await session.status(["x"])
            XCTFail("a corrupted record cannot decrypt")
        } catch {
            XCTAssertEqual(error as? SyncError, .connectionClosed)
        }
        XCTAssertEqual(proxy.corruptedRecords, 1)
        await session.close()
    }

    func testAWrongKeyIsStillAHandshakeFailure() async throws {
        let invite = server.makeInvite()
        let forged = PairedMac(
            macID: invite.macID, macName: invite.macName, deviceID: invite.deviceID,
            key: Data(repeating: 9, count: 32), pairedAt: Date())
        do {
            let session = try await client(forged).connect(timeout: 5)
            await session.close()
            XCTFail("a wrong key must not get a welcome")
        } catch {
            guard case .handshakeFailed? = error as? SyncError else {
                return XCTFail("expected handshakeFailed, got \(error)")
            }
        }
    }

    // MARK: discovery

    /// Local Network denial used to look like "Mac not found" after the full
    /// timeout.
    func testBrowseWithLocalNetworkDeniedFailsAtOnceAndTyped() async throws {
        let started = Date()
        do {
            _ = try await BonjourBrowsing.find(macID: UUID().uuidString, timeout: 5) { browser, queue in
                queue.async { browser.stateUpdateHandler?(.waiting(.dns(DiscoveryIssue.policyDeniedCode))) }
            }
            XCTFail("expected localNetworkDenied")
        } catch {
            XCTAssertEqual(error as? DiscoveryIssue, .localNetworkDenied)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "should not sit out the timeout")
    }

    func testBrowseStillWaitingAtTheDeadlineSaysWhy() async throws {
        do {
            _ = try await BonjourBrowsing.find(macID: UUID().uuidString, timeout: 0.5) { browser, queue in
                queue.async { browser.stateUpdateHandler?(.waiting(.dns(-65563))) }  // ServiceNotRunning
            }
            XCTFail("expected a discovery issue")
        } catch {
            guard case .browsingUnavailable? = error as? DiscoveryIssue else {
                return XCTFail("expected browsingUnavailable, got \(error)")
            }
        }
    }

    func testPresenceMonitorReportsLocalNetworkDenied() async throws {
        let monitor = MacPresenceMonitor(macID: UUID().uuidString)
        monitor.start()
        defer { monitor.stop() }
        monitor.deliverBrowserState(.waiting(.dns(DiscoveryIssue.policyDeniedCode)))
        XCTAssertEqual(monitor.issue, .localNetworkDenied)
        XCTAssertFalse(monitor.isReachable)
        var iterator = monitor.issueUpdates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .some(.localNetworkDenied), "current value first")

        monitor.deliverBrowserState(.ready)
        XCTAssertNil(monitor.issue)
    }

    /// iOS resets a suspended app's mDNSResponder connection, failing its
    /// browsers. The monitor used to stay "unreachable" for good (and start()
    /// was a no-op because the dead browser was still referenced).
    func testPresenceMonitorRecoversFromABrowserFailure() async throws {
        if ProcessInfo.processInfo.environment["HUSKE_SKIP_BONJOUR_TESTS"] == "1" {
            throw XCTSkip("HUSKE_SKIP_BONJOUR_TESTS=1")
        }
        let bonjourDir = dir.appendingPathComponent("bonjour", isDirectory: true)
        let bonjourRegistry = DeviceRegistry(fileURL: bonjourDir.appendingPathComponent("devices.json"))
        let advertised = SyncServer(
            registry: bonjourRegistry, stagingDirectory: bonjourDir.appendingPathComponent("staging"),
            macName: "Huske Test \(UUID().uuidString.prefix(6))", serverVersion: "test")
        try advertised.start()
        defer { advertised.stop() }
        _ = await advertised.waitUntilReady()

        let monitor = MacPresenceMonitor(macID: bonjourRegistry.macID)
        monitor.start()
        defer { monitor.stop() }
        let seen = await eventually(10) { monitor.isReachable }
        XCTAssertTrue(seen, "the advertised server was never seen")

        monitor.deliverBrowserState(.failed(.dns(-65569)))  // DefunctConnection
        XCTAssertFalse(monitor.isReachable)
        XCTAssertNotNil(monitor.issue)

        let back = await eventually(10) { monitor.isReachable }
        XCTAssertTrue(back, "the monitor never browsed again after its browser failed")
        XCTAssertNil(monitor.issue)
    }

    // MARK: status replies

    /// The server accepts 1000 IDs, but a reply for ~350 no longer fits the
    /// 64 KiB header, so the Mac hung up and every poll failed.
    func testStatusForHundredsOfIDs() async throws {
        let (_, session) = try await pair()
        delegate.setStatus(
            RemoteStatus(recordingID: "id-7", state: .received, detail: "Waiting for a huske engine that can transcribe phone recordings"))
        let ids = (0..<1000).map { "id-\($0)" }
        let items = try await session.status(ids)
        XCTAssertEqual(items.map(\.recordingID), ids)
        XCTAssertEqual(items[7].state, .received)
        XCTAssertEqual(items[8].state, .unknown)
        await session.close()
    }

    func testAnOversizedReplyIsAnErrorNotAHangUp() async throws {
        let (_, session) = try await pair()
        // An older client asks for 1000 at once (raw, no batching).
        let ids = (0..<1000).map { _ in UUID().uuidString }
        try await session.connection.send(.status(StatusRequestMessage(recordingIDs: ids)))
        let reply = try await session.connection.receive(timeout: 5)
        guard case .error(let error)? = reply else {
            return XCTFail("expected too_large, got \(String(describing: reply))")
        }
        XCTAssertEqual(error.code, "too_large")
        // The connection is still in a known position and keeps working.
        let items = try await session.status(["a"])
        XCTAssertEqual(items.first?.state, .unknown)
        await session.close()
    }

    func testAVerboseStatusDetailIsCappedNotFatal() async throws {
        let (_, session) = try await pair()
        let huge = String(repeating: "ção ", count: 30_000)  // ~150 KB of UTF-8
        delegate.setStatus(RemoteStatus(recordingID: "loud", state: .failed, detail: huge))
        let items = try await session.status(["loud"])
        let detail = try XCTUnwrap(items.first?.detail)
        XCTAssertEqual(items.first?.state, .failed)
        XCTAssertLessThanOrEqual(detail.utf8.count, SyncConstants.maxStatusDetailBytes)
        XCTAssertTrue(detail.hasPrefix("ção ção"))
        XCTAssertTrue(detail.hasSuffix("…"))
        await session.close()
    }

    // MARK: cancellation + timeouts

    /// "Forget this Mac" and background-time expiry cancel the sync task; the
    /// upload used to ignore that and send the whole file anyway.
    func testUploadStopsWhenItsTaskIsCancelledAndResumesLater() async throws {
        let (_, session) = try await pair()
        let (manifest, url, data) = try syntheticRecording(bytes: 2_000_000)
        let task = Task {
            try await session.upload(manifest: manifest, fileURL: url) { sent, _ in
                if sent > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("the upload ran to completion despite cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertTrue(delegate.received.isEmpty)

        // The same session is still in step; a later upload resumes.
        let seen = ProgressLog()
        let status = try await session.upload(manifest: manifest, fileURL: url) { sent, total in
            seen.append(sent, total)
        }
        XCTAssertGreaterThan(seen.values.first?.0 ?? 0, 0, "resumed, not restarted")
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(delegate.received.first?.1, data)
        await session.close()
    }

    /// A connection cancelled before it started (the server stopping between
    /// accept and serve) never reports a state again; start() used to wait
    /// forever, its timeout included.
    func testStartAfterCancelFailsInsteadOfHanging() async throws {
        let framed = FramedConnection(
            NWConnection(
                to: .hostPort(host: "127.0.0.1", port: 9),
                using: TLSPSK.clientParameters(identity: "x", key: Data(count: 32))),
            label: "cancelled-early")
        framed.cancel()
        let outcome = Outcome()
        Task {
            do {
                try await framed.start(timeout: 1)
                outcome.set("ready")
            } catch {
                outcome.set("\(error)")
            }
        }
        let finished = await eventually(3) { outcome.value != nil }
        XCTAssertTrue(finished, "start() hung past its timeout")
        XCTAssertEqual(outcome.value, "\(SyncError.connectionClosed)")
    }

    /// A session dropped without close() used to keep its socket open on both
    /// ends until the Mac's 2-minute idle timeout.
    func testADroppedSessionClosesItsConnection() async throws {
        let pairing = PairedMac(invite: server.makeInvite())
        do {
            let session = try await client(pairing).connect(timeout: 5)
            XCTAssertEqual(session.welcome.macID, registry.macID)
        }
        let events = self.events!
        let closed = await eventually(3) {
            events.values.contains { if case .deviceDisconnected = $0 { return true } else { return false } }
        }
        XCTAssertTrue(closed, "the Mac still holds the dropped session's connection")
    }
}

// MARK: - test doubles

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [SyncServerEvent] = []
    func append(_ event: SyncServerEvent) { lock.withLock { _values.append(event) } }
    var values: [SyncServerEvent] { lock.withLock { _values } }
}

final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    func set(_ value: String) { lock.withLock { _value = value } }
    var value: String? { lock.withLock { _value } }
}

// The byte-flipping relay this file used to carry is `FaultProxy`
// (FaultProxy.swift) now, shared with FaultInjectionTests.
