// The link supervisor's building blocks in HuskeSync: the presence monitor
// hands out the Mac's endpoint and browse state, the client connects to that
// endpoint without browsing again, and a connection that hits a *path* error
// gets a short grace period while a refused port or a TLS rejection still
// fails at once. Deterministic: states and sightings are delivered through the
// test seams; only `testConnectUsingTheEndpointThePresenceMonitorFound` needs
// real Bonjour (skip with HUSKE_SKIP_BONJOUR_TESTS=1).

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

/// A plain TCP listener that accepts and then says nothing: a client's TLS
/// handshake against it stays `.preparing` until the client gives up.
private final class SilentListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "huske.test.silent")
    private let lock = NSLock()
    private var held: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.held.append(connection) }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    func port() async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SyncError.timeout
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ held }) { connection.cancel() }
    }
}

final class LinkTests: XCTestCase {
    private var dir: URL!
    private var server: SyncServer!
    private var registry: DeviceRegistry!
    private var delegate: FakeDelegate!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registry = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        server = SyncServer(
            registry: registry, stagingDirectory: dir.appendingPathComponent("staging"),
            macName: "Test Mac", serverVersion: "test")
        delegate = FakeDelegate()
        server.delegate = delegate
        server.advertisesService = false
        try server.start()
        let port = await server.waitUntilReady()
        XCTAssertNotNil(port)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private func loopback(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    private func serverEndpoint() async throws -> NWEndpoint {
        let port = await server.waitUntilReady()
        return loopback(try XCTUnwrap(port, "listener not ready"))
    }

    /// The production client: no test endpoint, so `connect(timeout:)` would
    /// have to find the Mac on Bonjour (and this server doesn't advertise).
    private func productionClient(_ pairing: PairedMac) -> SyncClient {
        SyncClient(pairing: pairing, deviceName: "iPhone de Teste", deviceModel: "iPhone17,1", appVersion: "1.0")
    }

    private func eventually(_ timeout: TimeInterval, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A client connection whose TLS handshake hangs (so it reports nothing
    /// by itself), with `start(timeout:)` already waiting on it.
    private func hangingConnection(
        to listener: SilentListener, pathGrace: TimeInterval, timeout: TimeInterval = 10
    ) async throws -> (FramedConnection, Task<Result<Void, Error>, Never>) {
        let params = TLSPSK.clientParameters(identity: "test-device", key: Data(repeating: 1, count: 32))
        let framed = FramedConnection(
            NWConnection(to: loopback(try await listener.port()), using: params),
            label: "test-client", pathGrace: pathGrace)
        let start = Task { () -> Result<Void, Error> in
            do {
                try await framed.start(timeout: timeout)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        // Past Network.framework's own `.preparing`, so it can't arrive after
        // (and undo) a state the test delivers.
        let waiting = await eventually(3) { framed.isAwaitingReady && framed.connection.state == .preparing }
        XCTAssertTrue(waiting, "the connection never started preparing")
        return (framed, start)
    }

    // MARK: connect(to:)

    /// The presence monitor already knows where the Mac is; browsing again
    /// cost most of a second per connection, and 8 s when the Mac was away.
    func testConnectToAKnownEndpointDoesNotBrowse() async throws {
        let pairing = PairedMac(invite: server.makeInvite())
        let endpoint = try await serverEndpoint()
        let started = Date()

        let session = try await productionClient(pairing).connect(to: endpoint, timeout: 5)

        XCTAssertEqual(session.welcome.macID, registry.macID)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "no browse: a known endpoint connects at once")
        XCTAssertEqual(session.route, .loopback)
        await session.close()
    }

    /// An endpoint is only a place to knock: the answer must still come from
    /// the paired Mac.
    func testConnectToAnEndpointStillChecksWhichMacAnswered() async throws {
        let invite = server.makeInvite()
        let pairing = PairedMac(
            macID: "some-other-mac", macName: "Other", deviceID: invite.deviceID, key: invite.key, pairedAt: Date())
        let endpoint = try await serverEndpoint()

        do {
            let session = try await productionClient(pairing).connect(to: endpoint, timeout: 5)
            await session.close()
            XCTFail("a different Mac's welcome was accepted")
        } catch let SyncError.protocolError(code, _) {
            XCTAssertEqual(code, "wrong_mac")
        }
    }

    // MARK: `.waiting` before `.ready`

    func testOnlyPathProblemsCountAsPathErrors() {
        for code in [POSIXErrorCode.ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .EADDRNOTAVAIL] {
            XCTAssertTrue(FramedConnection.isPathError(.posix(code)), "\(code) is curable by a path change")
        }
        XCTAssertTrue(FramedConnection.isPathError(.dns(-65554)), "the Bonjour name hasn't resolved yet")
        XCTAssertFalse(FramedConnection.isPathError(.posix(.ECONNREFUSED)), "the port answered: no")
        XCTAssertFalse(FramedConnection.isPathError(.posix(.ECONNRESET)))
        XCTAssertFalse(FramedConnection.isPathError(.tls(-9806)), "the Mac rejected the key")
    }

    /// A refused port is an answer, not a path problem: no grace period.
    func testARefusedConnectionFailsFast() async throws {
        // A port that was just listening and no longer is.
        let closed = try SilentListener()
        let port = try await closed.port()
        closed.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let pairing = PairedMac(invite: server.makeInvite())
        let started = Date()

        do {
            let session = try await productionClient(pairing).connect(to: loopback(port), timeout: 8)
            await session.close()
            XCTFail("connected to a closed port")
        } catch {
            XCTAssertLessThan(
                Date().timeIntervalSince(started), FramedConnection.defaultPathGrace - 1,
                "refused must not wait out the path grace period (got \(error))")
        }
    }

    /// `.waiting` used to be fatal whatever the reason, so a connection made
    /// while the network was still coming up (app just became active, Wi-Fi
    /// handover) failed although it would have gone through a moment later.
    func testAPathErrorThatClearsInTimeStillConnects() async throws {
        let listener = try SilentListener()
        defer { listener.stop() }
        let (framed, start) = try await hangingConnection(to: listener, pathGrace: 5)
        defer { framed.cancel() }

        framed.deliverState(.waiting(.posix(.ENETUNREACH)))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(framed.isAwaitingReady, "a path error is not fatal right away")

        framed.deliverState(.ready)
        guard case .success = await start.value else {
            return XCTFail("the connection became ready within the grace period")
        }
    }

    func testAPathErrorThatOutlastsTheGracePeriodFailsWithThatError() async throws {
        let listener = try SilentListener()
        defer { listener.stop() }
        let (framed, start) = try await hangingConnection(to: listener, pathGrace: 0.2, timeout: 10)
        defer { framed.cancel() }
        let began = Date()

        framed.deliverState(.waiting(.posix(.ENETUNREACH)))

        guard case .failure(let error) = await start.value else {
            return XCTFail("expected the attempt to fail once the grace period ran out")
        }
        XCTAssertEqual(error as? SyncError, FramedConnection.map(.posix(.ENETUNREACH)))
        XCTAssertLessThan(Date().timeIntervalSince(began), 3, "the grace period ends it, not the 10 s timeout")
        let released = await eventually(2) { framed.connection.state == .cancelled }
        XCTAssertTrue(released, "a failed attempt must not leave its connection open")
    }

    /// Network.framework goes back to `.preparing` when the path changes: the
    /// old path error must not end an attempt that is making progress again.
    func testRetryingAfterAPathChangeDropsTheOldPathError() async throws {
        let listener = try SilentListener()
        defer { listener.stop() }
        let (framed, start) = try await hangingConnection(to: listener, pathGrace: 0.2, timeout: 10)

        framed.deliverState(.waiting(.posix(.ENETDOWN)))
        framed.deliverState(.preparing)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(framed.isAwaitingReady, "still connecting: the grace period no longer applies")
        framed.cancel()
        guard case .failure = await start.value else { return XCTFail("cancelled connection reported ready") }
    }

    /// A TLS rejection while connecting keeps failing at once — and as a
    /// handshake failure, even if a path error came first.
    func testATLSRejectionFailsFastEvenAfterAPathError() async throws {
        let listener = try SilentListener()
        defer { listener.stop() }
        let (framed, start) = try await hangingConnection(to: listener, pathGrace: 5)
        defer { framed.cancel() }
        let began = Date()

        framed.deliverState(.waiting(.posix(.ENETDOWN)))
        framed.deliverState(.waiting(.tls(-9806)))

        guard case .failure(let error) = await start.value else { return XCTFail("expected a handshake failure") }
        guard case .handshakeFailed? = error as? SyncError else {
            return XCTFail("expected handshakeFailed, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
    }

    // MARK: the address behind the service, then the service

    /// Connecting to the one address a service resolved to must not cost
    /// reachability: when that address says nothing, the service endpoint
    /// (where Network.framework tries every address) gets the rest of the time.
    func testAnAddressThatDoesNotAnswerGivesWayToTheServiceEndpoint() async throws {
        let pairing = PairedMac(invite: server.makeInvite())
        let real = try await serverEndpoint()
        let silent = try SilentListener()
        defer { silent.stop() }
        let deadEnd = loopback(try await silent.port())
        let started = Date()

        let connection = try await BonjourBrowsing.openConnection(
            to: real, deadline: Date().addingTimeInterval(8),
            parameters: { TLSPSK.clientParameters(identity: pairing.deviceID, key: pairing.key) },
            directLimit: 0.3,
            resolve: { _, _ in deadEnd })
        defer { connection.cancel() }

        XCTAssertFalse(connection.isClosed)
        XCTAssertEqual(connection.endpointDescription, "\(real)", "connected through the service endpoint")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// A refused port is the Mac's answer; trying the service endpoint as
    /// well would only wait out the timeout to learn nothing new.
    func testAnAddressThatRefusesIsTheAnswer() async throws {
        let pairing = PairedMac(invite: server.makeInvite())
        let real = try await serverEndpoint()
        let closed = try SilentListener()
        let closedPort = try await closed.port()
        closed.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let refused = loopback(closedPort)
        let started = Date()

        do {
            let connection = try await BonjourBrowsing.openConnection(
                to: real, deadline: Date().addingTimeInterval(8),
                parameters: { TLSPSK.clientParameters(identity: pairing.deviceID, key: pairing.key) },
                resolve: { _, _ in refused })
            connection.cancel()
            XCTFail("the refusing address was skipped for the service endpoint")
        } catch {
            XCTAssertNotEqual(error as? SyncError, .timeout)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    /// The rejection is the answer too — and must arrive as one.
    func testARejectedKeyAtTheAddressIsNotRetriedOnTheServiceEndpoint() async throws {
        let invite = server.makeInvite()
        let real = try await serverEndpoint()
        let silent = try SilentListener()
        defer { silent.stop() }
        let wouldHang = loopback(try await silent.port())
        let started = Date()

        do {
            let connection = try await BonjourBrowsing.openConnection(
                to: wouldHang, deadline: Date().addingTimeInterval(8),
                parameters: { TLSPSK.clientParameters(identity: invite.deviceID, key: Data(repeating: 5, count: 32)) },
                resolve: { _, _ in real })
            connection.cancel()
            XCTFail("connected with the wrong key")
        } catch {
            guard case .handshakeFailed? = error as? SyncError else {
                return XCTFail("expected handshakeFailed, got \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "no second attempt on the endpoint that hangs")
        }
    }

    func testOnlySilenceCountsAsNoAnswer() async throws {
        let listener = try SilentListener()
        defer { listener.stop() }

        // No path, for longer than the grace period.
        let (unreachable, first) = try await hangingConnection(to: listener, pathGrace: 0.1)
        unreachable.deliverState(.waiting(.posix(.EHOSTUNREACH)))
        _ = await first.value
        XCTAssertTrue(unreachable.gotNoAnswer)

        // Nothing at all until the timeout.
        let (silent, second) = try await hangingConnection(to: listener, pathGrace: 5, timeout: 0.3)
        _ = await second.value
        XCTAssertTrue(silent.gotNoAnswer)

        // The Mac said no.
        let (rejected, third) = try await hangingConnection(to: listener, pathGrace: 5)
        rejected.deliverState(.waiting(.tls(-9806)))
        _ = await third.value
        XCTAssertFalse(rejected.gotNoAnswer)

        let (refused, fourth) = try await hangingConnection(to: listener, pathGrace: 5)
        refused.deliverState(.waiting(.posix(.ECONNREFUSED)))
        _ = await fourth.value
        XCTAssertFalse(refused.gotNoAnswer)
    }

    // MARK: routes

    func testRoutesAreNamedByInterface() {
        XCTAssertEqual(SyncRoute(interfaceName: "en0", type: .wifi), .wifi)
        XCTAssertEqual(SyncRoute(interfaceName: "en5", type: .wiredEthernet), .wired)
        XCTAssertEqual(SyncRoute(interfaceName: "lo0", type: .loopback), .loopback)
        XCTAssertEqual(SyncRoute(interfaceName: "utun3", type: .other), .other)
        // Peer-to-peer Wi-Fi has a generic type; only its name gives it away.
        XCTAssertEqual(SyncRoute(interfaceName: "awdl0", type: .other), .peerToPeer)
        XCTAssertEqual(SyncRoute(interfaceName: "awdl0", type: .wifi), .peerToPeer)
        XCTAssertEqual(SyncRoute(interfaceName: "llw0", type: .other), .peerToPeer)
    }

    // MARK: presence

    func testPresenceCarriesTheEndpointAndTheBrowseState() async throws {
        let monitor = MacPresenceMonitor(macID: UUID().uuidString)
        XCTAssertEqual(monitor.presence, MacPresence(), "not asked to look yet")

        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.presence.isBrowsing)
        XCTAssertNil(monitor.endpoint)

        let endpoint = loopback(4242)
        monitor.deliverSighting(endpoint, routes: [.wifi])
        XCTAssertEqual(monitor.presence, MacPresence(isBrowsing: true, endpoint: endpoint, routes: [.wifi]))
        XCTAssertTrue(monitor.presence.isVisible)
        XCTAssertTrue(monitor.isReachable, "the Bool view agrees")

        monitor.deliverSighting(nil)
        XCTAssertNil(monitor.endpoint)
        XCTAssertFalse(monitor.isReachable)
    }

    /// With Local Network access off the browser can't see anything: whatever
    /// it reported before must not be offered as a place to connect to.
    func testAnIssueHidesTheEndpoint() async throws {
        let monitor = MacPresenceMonitor(macID: UUID().uuidString)
        monitor.start()
        defer { monitor.stop() }
        monitor.deliverSighting(loopback(4242))

        monitor.deliverBrowserState(.waiting(.dns(DiscoveryIssue.policyDeniedCode)))

        XCTAssertEqual(monitor.presence, MacPresence(isBrowsing: true, issue: .localNetworkDenied))
    }

    func testStoppingReportsNotBrowsing() async throws {
        let monitor = MacPresenceMonitor(macID: UUID().uuidString)
        monitor.start()
        monitor.deliverSighting(loopback(4242))

        monitor.stop()

        XCTAssertEqual(monitor.presence, MacPresence(), "stopped: not looking, nothing visible")
    }

    /// The supervisor reacts to events, so every change must arrive, in
    /// order, starting from the current value — including "still visible,
    /// but now seen another way".
    func testPresenceUpdatesEmitEveryChangeInOrder() async throws {
        let monitor = MacPresenceMonitor(macID: UUID().uuidString)
        var updates = monitor.presenceUpdates.makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial, MacPresence(), "current value first")

        let endpoint = loopback(4242)
        monitor.start()
        monitor.deliverSighting(endpoint, routes: [.peerToPeer])
        monitor.deliverSighting(endpoint, routes: [.wifi, .peerToPeer])
        monitor.deliverSighting(endpoint, routes: [.wifi, .peerToPeer])  // no change: no event
        monitor.deliverSighting(nil)
        monitor.stop()

        var seen: [MacPresence] = []
        for _ in 0..<5 {
            guard let next = await updates.next() else { break }
            seen.append(next)
        }
        XCTAssertEqual(seen, [
            MacPresence(isBrowsing: true),
            MacPresence(isBrowsing: true, endpoint: endpoint, routes: [.peerToPeer]),
            MacPresence(isBrowsing: true, endpoint: endpoint, routes: [.wifi, .peerToPeer]),
            MacPresence(isBrowsing: true),
            MacPresence(),
        ])
    }

    // MARK: over real Bonjour

    /// An advertised server with its own identity, the endpoint a presence
    /// monitor reports for it, and a pairing it accepts.
    private func advertisedServer() async throws -> (SyncServer, DeviceRegistry, NWEndpoint, PairedMac, MacPresenceMonitor) {
        if ProcessInfo.processInfo.environment["HUSKE_SKIP_BONJOUR_TESTS"] == "1" {
            throw XCTSkip("HUSKE_SKIP_BONJOUR_TESTS=1")
        }
        let bonjourDir = dir.appendingPathComponent("bonjour-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let bonjourRegistry = DeviceRegistry(fileURL: bonjourDir.appendingPathComponent("devices.json"))
        let advertised = SyncServer(
            registry: bonjourRegistry, stagingDirectory: bonjourDir.appendingPathComponent("staging"),
            macName: "Huske Test \(UUID().uuidString.prefix(6))", serverVersion: "test")
        advertised.delegate = delegate
        try advertised.start()
        let pairing = PairedMac(invite: advertised.makeInvite())
        _ = await advertised.waitUntilReady()

        let monitor = MacPresenceMonitor(macID: bonjourRegistry.macID)
        monitor.start()
        let seen = await eventually(10) { monitor.endpoint != nil }
        guard seen, let endpoint = monitor.endpoint else {
            monitor.stop()
            advertised.stop()
            throw XCTSkip("the advertised server was never seen on Bonjour")
        }
        return (advertised, bonjourRegistry, endpoint, pairing, monitor)
    }

    /// The real thing: the monitor finds an advertised server and the client
    /// connects to the endpoint it reports, with no second browse.
    func testConnectUsingTheEndpointThePresenceMonitorFound() async throws {
        let (advertised, bonjourRegistry, endpoint, pairing, monitor) = try await advertisedServer()
        defer {
            monitor.stop()
            advertised.stop()
        }
        XCTAssertFalse(monitor.presence.routes.isEmpty, "a sighting says how the Mac was seen")

        let session = try await productionClient(pairing).connect(to: endpoint, timeout: 8)
        XCTAssertEqual(session.welcome.macID, bonjourRegistry.macID)
        await session.close()
    }

    /// Found end to end: the Mac refused a forgotten key in ~130 ms, but the
    /// phone reported "took too long" 8 s later. Network.framework never
    /// reports a TLS rejection on a connection to a *service* endpoint — it
    /// keeps "preparing" — so the client connects to the address behind it.
    func testARejectedKeyOverBonjourIsAHandshakeFailureNotATimeout() async throws {
        let (advertised, bonjourRegistry, endpoint, pairing, monitor) = try await advertisedServer()
        defer {
            monitor.stop()
            advertised.stop()
        }
        // An identity the Mac never minted (a pruned invite), and a known
        // identity with the wrong key.
        let forgotten = PairedMac(
            macID: bonjourRegistry.macID, macName: "Test", deviceID: UUID().uuidString,
            key: Data(repeating: 3, count: 32), pairedAt: Date())
        let wrongKey = PairedMac(
            macID: bonjourRegistry.macID, macName: "Test", deviceID: pairing.deviceID,
            key: Data(repeating: 4, count: 32), pairedAt: Date())

        for (label, rejected) in [("unknown identity", forgotten), ("wrong key", wrongKey)] {
            let started = Date()
            do {
                let session = try await productionClient(rejected).connect(to: endpoint, timeout: 8)
                await session.close()
                XCTFail("\(label): connected with a key the Mac doesn't accept")
            } catch {
                guard case .handshakeFailed? = error as? SyncError else {
                    XCTFail("\(label): expected handshakeFailed, got \(error)")
                    continue
                }
                XCTAssertLessThan(Date().timeIntervalSince(started), 3, "\(label): the rejection is immediate")
            }
        }
    }

    func testResolveFindsTheAddressBehindAService() async throws {
        let (advertised, _, endpoint, _, monitor) = try await advertisedServer()
        defer {
            monitor.stop()
            advertised.stop()
        }
        guard case .service = endpoint else { return XCTFail("a browse result is a service endpoint") }
        let port = await advertised.waitUntilReady()

        let address = await BonjourBrowsing.resolve(endpoint, timeout: 5)

        guard case let .hostPort(_, resolvedPort)? = address else {
            return XCTFail("expected a concrete address, got \(String(describing: address))")
        }
        XCTAssertEqual(resolvedPort.rawValue, port)
    }

    func testResolveLeavesAConcreteAddressAlone() async {
        let address = loopback(4242)

        let resolved = await BonjourBrowsing.resolve(address, timeout: 5)

        XCTAssertEqual(resolved, address)
    }

    /// When the name doesn't resolve the client falls back to the service
    /// endpoint itself, so this must come back (with nothing) in time.
    func testResolveGivesUpOnAServiceThatIsNotThere() async {
        let missing = NWEndpoint.service(
            name: "huske-missing-\(UUID().uuidString)", type: SyncConstants.serviceType, domain: "local.", interface: nil)
        let started = Date()

        let resolved = await BonjourBrowsing.resolve(missing, timeout: 0.4)

        XCTAssertNil(resolved)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
