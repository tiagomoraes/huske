// "Can my iPhone reach this Mac right now?" — SyncServer's own answer.
//
// A bound port used to be the whole answer, so the Mac could say "Ready" with
// no advert for a phone to find. These pin the pieces: the advert must be
// confirmed, a missing or withdrawn one is announced again, a failed or
// waiting listener comes back, `recheck` repairs at once instead of waiting
// out a backoff step, and every request counts as contact from a phone.
//
// Deterministic: adverts are simulated (`simulatesAdvertRegistration`), so
// nothing here needs mDNS. One test at the end uses the real thing and can be
// skipped with HUSKE_SKIP_BONJOUR_TESTS=1.

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

final class ListenerHealthTests: XCTestCase {
    private var dir: URL!
    private var server: SyncServer!
    private var registry: DeviceRegistry!
    private var delegate: RetryingDelegate!
    private var events: EventLog!
    private var healths: HealthLog!

    private let advert = NWEndpoint.service(
        name: "Test Mac", type: SyncConstants.serviceType, domain: "local.", interface: nil)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    /// A server that is not started yet, with every timer shortened.
    private func makeServer(advertised: Bool, port: UInt16 = 0) -> SyncServer {
        registry = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        let server = SyncServer(
            registry: registry, stagingDirectory: dir.appendingPathComponent("staging"),
            macName: "Test Mac", serverVersion: "test", port: port)
        delegate = RetryingDelegate()
        server.delegate = delegate
        server.advertisesService = advertised
        server.simulatesAdvertRegistration = advertised
        server.advertGrace = 0.2
        server.recheckDebounce = 0
        server.retryDelayOverride = { _ in 0.1 }
        events = EventLog()
        healths = HealthLog()
        let (events, healths) = (self.events!, self.healths!)
        server.onEvent = { events.append($0) }
        server.onHealthChange = { healths.append($0) }
        if ProcessInfo.processInfo.environment["HUSKE_SYNC_TEST_LOG"] == "1" {
            server.logHandler = { print("[server] \($0)") }
        }
        self.server = server
        return server
    }

    private func eventually(
        _ timeout: TimeInterval = 5, _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private var listeningEvents: Int {
        events.values.filter { if case .listening = $0 { return true } else { return false } }.count
    }

    private func client(_ pairing: PairedMac, port: UInt16) -> SyncClient {
        SyncClient(
            pairing: pairing, deviceName: "iPhone de Teste", deviceModel: "iPhone17,1", appVersion: "1.0",
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    private func pair() async throws -> (PairedMac, SyncSession) {
        let pairing = PairedMac(invite: server.makeInvite())
        let ready = await server.waitUntilReady()
        let port = try XCTUnwrap(ready, "listener not ready")
        return (pairing, try await client(pairing, port: port).connect(timeout: 5))
    }

    /// Confirms the simulated advert on whatever listener is current.
    private func confirmAdvert() async -> Bool {
        let (server, advert) = (self.server!, self.advert)
        return await eventually {
            server.simulateServiceRegistration(.add(advert))
            return server.health.isReachable
        }
    }

    // MARK: the advert

    /// "Ready" used to mean "the port is bound". With no advert no phone can
    /// find the Mac, so that alone must not read as reachable.
    func testABoundPortIsNotReachableUntilTheAdvertIsConfirmed() async throws {
        let server = makeServer(advertised: true)
        server.advertGrace = 30  // not the subject here
        try server.start()
        let ready = await server.waitUntilReady()
        let port = try XCTUnwrap(ready)
        XCTAssertEqual(server.health, .starting, "bound, but nothing confirmed the advert")
        XCTAssertFalse(server.health.isReachable)

        server.simulateServiceRegistration(.add(advert))
        XCTAssertEqual(server.health, .listening(port: port))
        XCTAssertEqual(healths.values, [.starting, .listening(port: port)])
    }

    func testAServerThatDoesNotAdvertiseIsReachableOnceBound() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        let ready = await server.waitUntilReady()
        let port = try XCTUnwrap(ready)
        let reachable = await eventually { server.health == .listening(port: port) }
        XCTAssertTrue(reachable, "\(server.health)")
    }

    /// The system never confirms: say so, and announce again by rebuilding the
    /// listener — on a backoff, until it takes.
    func testAnAdvertThatNeverRegistersIsReportedAndAnnouncedAgain() async throws {
        let server = makeServer(advertised: true)
        try server.start()
        _ = await server.waitUntilReady()

        let reported = await eventually { server.health == .notAdvertising(.advertNotRegistered) }
        XCTAssertTrue(reported, "\(server.health)")
        XCTAssertNotNil(server.port, "the listener itself is fine")

        let events = self.events!
        let rebuilt = await eventually {
            events.values.filter { if case .listening = $0 { return true } else { return false } }.count >= 2
        }
        XCTAssertTrue(rebuilt, "the listener was never rebuilt to announce again")
        XCTAssertEqual(server.health, .notAdvertising(.advertNotRegistered), "still unconfirmed")

        let confirmed = await confirmAdvert()
        XCTAssertTrue(confirmed, "\(server.health)")
    }

    /// The system takes the advert back (a network change, mDNSResponder
    /// restarting) while the listener stays bound.
    func testAWithdrawnAdvertIsNoticedAndAnnouncedAgain() async throws {
        let server = makeServer(advertised: true)
        try server.start()
        _ = await server.waitUntilReady()
        let confirmedFirst = await confirmAdvert()
        XCTAssertTrue(confirmedFirst)
        let before = listeningEvents

        server.simulateServiceRegistration(.remove(advert))
        XCTAssertTrue(server.health.isReachable, "a blip inside the grace period is not a problem yet")
        let reported = await eventually { server.health == .notAdvertising(.advertNotRegistered) }
        XCTAssertTrue(reported, "\(server.health)")

        let events = self.events!
        let rebuilt = await eventually {
            events.values.filter { if case .listening = $0 { return true } else { return false } }.count > before
        }
        XCTAssertTrue(rebuilt)
        let confirmedAgain = await confirmAdvert()
        XCTAssertTrue(confirmedAgain, "\(server.health)")
    }

    /// A withdrawal the system undoes by itself costs nothing.
    func testAnAdvertThatComesStraightBackIsNotRebuilt() async throws {
        let server = makeServer(advertised: true)
        try server.start()
        _ = await server.waitUntilReady()
        let confirmed = await confirmAdvert()
        XCTAssertTrue(confirmed)
        let before = listeningEvents

        server.simulateServiceRegistration(.remove(advert))
        server.simulateServiceRegistration(.add(advert))
        try await Task.sleep(nanoseconds: 600_000_000)  // grace + retry delay, twice over
        XCTAssertTrue(server.health.isReachable)
        XCTAssertEqual(listeningEvents, before, "no rebuild for a blip")
    }

    // MARK: the listener

    func testHealthFollowsAFailedListenerBackToListening() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        _ = await server.waitUntilReady()
        let healthy = await eventually { server.health.isReachable }
        XCTAssertTrue(healthy)

        server.simulateListenerState(.failed(.posix(.ENETDOWN)))
        XCTAssertEqual(server.health, .recovering(.noNetwork))
        XCTAssertTrue(server.isRunning)

        let back = await eventually { server.health.isReachable }
        XCTAssertTrue(back, "\(server.health)")
        XCTAssertEqual(healths.values.count, 4, "\(healths.values)")
        XCTAssertEqual(healths.values.first, .starting)
        XCTAssertEqual(healths.values[2], .recovering(.noNetwork))

        let (_, session) = try await pair()
        _ = try await session.status(["x"])
        await session.close()
    }

    func testAWaitingListenerSaysWhyPhonesCannotFindTheMac() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        _ = await server.waitUntilReady()

        server.simulateListenerState(.waiting(.dns(DiscoveryIssue.policyDeniedCode)))
        XCTAssertEqual(server.health, .notAdvertising(.localNetworkDenied))
        server.simulateListenerState(.waiting(.posix(.ENETDOWN)))
        XCTAssertEqual(server.health, .notAdvertising(.noNetwork))

        server.simulateListenerState(.ready)
        XCTAssertTrue(server.health.isReachable)
    }

    /// A real failure, not a simulated one: something else holds the port.
    /// The server keeps trying and takes the port the moment it is free.
    func testAPortSomethingElseHoldsIsRetriedUntilItIsFree() async throws {
        let squatter = try PortSquatter()
        let server = makeServer(advertised: false, port: squatter.port)
        try server.start()

        let events = self.events!
        let failed = await eventually {
            events.values.contains { if case .listenerFailed = $0 { return true } else { return false } }
        }
        XCTAssertTrue(failed, "binding a taken port should fail")
        if case .recovering = server.health {} else { XCTFail("expected recovering, got \(server.health)") }
        XCTAssertTrue(server.isRunning)
        XCTAssertNil(server.port)
        XCTAssertNotNil(server.lastError)

        let held = squatter.port
        squatter.release()
        let port = await server.waitUntilReady(timeout: 10)
        XCTAssertEqual(port, held, "the listener never took the freed port")
        let healthy = await eventually { server.health == .listening(port: held) }
        XCTAssertTrue(healthy, "\(server.health)")
        XCTAssertNil(server.lastError)

        let (_, session) = try await pair()
        await session.close()
    }

    func testStoppingClearsHealth() async throws {
        let server = makeServer(advertised: false)
        XCTAssertEqual(server.health, .stopped)
        try server.start()
        _ = await server.waitUntilReady()
        server.stop()
        XCTAssertEqual(server.health, .stopped)
        XCTAssertEqual(healths.values.last, .stopped)
    }

    // MARK: recheck (the Mac woke, the network changed)

    func testRecheckRestartsADownListenerWithoutWaitingOutTheBackoff() async throws {
        let server = makeServer(advertised: false)
        server.retryDelayOverride = { _ in 120 }  // on its own it would be gone for two minutes
        try server.start()
        _ = await server.waitUntilReady()

        server.simulateListenerState(.failed(.posix(.ENETDOWN)))
        let stillDown = await server.waitUntilReady(timeout: 0.4)
        XCTAssertNil(stillDown, "nothing should restart it yet")

        server.recheck(reason: "woke from sleep")
        let port = await server.waitUntilReady(timeout: 5)
        XCTAssertNotNil(port, "recheck did not bring the listener back")
        let healthy = await eventually { server.health.isReachable }
        XCTAssertTrue(healthy, "\(server.health)")
    }

    func testRecheckRebuildsAWaitingListener() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        _ = await server.waitUntilReady()
        let before = listeningEvents

        server.simulateListenerState(.waiting(.posix(.ENETDOWN)))
        XCTAssertFalse(server.health.isReachable)
        server.recheck(reason: "the network changed")

        let events = self.events!
        let rebuilt = await eventually {
            events.values.filter { if case .listening = $0 { return true } else { return false } }.count > before
        }
        XCTAssertTrue(rebuilt)
        let healthy = await eventually { server.health.isReachable }
        XCTAssertTrue(healthy, "\(server.health)")
    }

    /// After a sleep the system can still say "registered" while nothing
    /// finds the advert. `recheck` looks the way a phone does.
    func testRecheckAnnouncesAgainWhenTheAdvertIsNotVisible() async throws {
        let server = makeServer(advertised: true)
        server.advertGrace = 30
        let probed = Counter()
        server.advertProbe = { _ in
            probed.increment()
            return false
        }
        try server.start()
        _ = await server.waitUntilReady()
        let confirmed = await confirmAdvert()
        XCTAssertTrue(confirmed)
        let before = listeningEvents

        server.recheck(reason: "woke from sleep")
        let reported = await eventually { server.health == .notAdvertising(.advertNotRegistered) }
        XCTAssertTrue(reported, "\(server.health)")
        let events = self.events!
        let rebuilt = await eventually {
            events.values.filter { if case .listening = $0 { return true } else { return false } }.count > before
        }
        XCTAssertTrue(rebuilt, "the listener was not rebuilt to announce again")
        XCTAssertEqual(probed.value, 1)

        let again = await confirmAdvert()
        XCTAssertTrue(again, "\(server.health)")
    }

    func testRecheckLeavesAVisibleAdvertAlone() async throws {
        for answer in [true, nil] as [Bool?] {
            server?.stop()
            let server = makeServer(advertised: true)
            server.advertGrace = 30
            let probed = Counter()
            server.advertProbe = { _ in
                probed.increment()
                return answer  // nil: Bonjour could not say — no evidence, no rebuild
            }
            try server.start()
            _ = await server.waitUntilReady()
            let confirmed = await confirmAdvert()
            XCTAssertTrue(confirmed)
            let before = listeningEvents

            server.recheck(reason: "the network changed")
            let asked = await eventually { probed.value == 1 }
            XCTAssertTrue(asked, "recheck never looked for the advert")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(server.health.isReachable, "answer \(String(describing: answer)): \(server.health)")
            XCTAssertEqual(listeningEvents, before, "answer \(String(describing: answer)): rebuilt for nothing")
        }
    }

    /// Announcing again replaces the listener, not the connections it already
    /// accepted: an upload in flight must not pay for a repair.
    func testARebuildDoesNotDropAPhoneThatIsConnected() async throws {
        let server = makeServer(advertised: true)
        server.advertGrace = 30
        server.advertProbe = { _ in false }
        try server.start()
        _ = await server.waitUntilReady()
        let confirmed = await confirmAdvert()
        XCTAssertTrue(confirmed)
        let (pairing, session) = try await pair()
        let before = listeningEvents

        server.recheck(reason: "woke from sleep")
        let events = self.events!
        let rebuilt = await eventually {
            events.values.filter { if case .listening = $0 { return true } else { return false } }.count > before
        }
        XCTAssertTrue(rebuilt)

        let items = try await session.status(["x"])
        XCTAssertEqual(items.first?.state, .unknown, "the session opened before the rebuild still answers")
        XCTAssertEqual(server.connectedDeviceIDs, [pairing.deviceID])
        await session.close()
    }

    func testRecheckBurstsAreCoalesced() async throws {
        let server = makeServer(advertised: true)
        server.advertGrace = 30
        server.recheckDebounce = 0.2
        let probed = Counter()
        server.advertProbe = { _ in
            probed.increment()
            return true
        }
        try server.start()
        _ = await server.waitUntilReady()
        let confirmed = await confirmAdvert()
        XCTAssertTrue(confirmed)

        for _ in 0..<5 { server.recheck(reason: "the network changed") }
        let asked = await eventually { probed.value >= 1 }
        XCTAssertTrue(asked)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(probed.value, 1, "a wake brings several network changes; one look is enough")
    }

    func testRecheckOnAStoppedServerDoesNothing() async throws {
        let server = makeServer(advertised: false)
        server.recheck(reason: "woke from sleep")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.health, .stopped)
        XCTAssertFalse(server.isRunning)
    }

    func testRepeatingFailuresAreLoggedSparingly() {
        // At the 30 s cap a failure that never clears would otherwise write
        // 2 900 identical lines a day and bury what led up to it.
        let logged = (1...60).filter { SyncServer.isWorthLogging(repeat: $0) }
        XCTAssertEqual(logged, [1, 2, 3, 10, 20, 30, 40, 50, 60])
    }

    // MARK: last contact

    /// `lastSeenAt` only moved on `hello`, so a phone that stayed connected to
    /// poll looked "last seen an hour ago" while it was talking to the Mac.
    func testEveryRequestCountsAsContact() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        let (pairing, session) = try await pair()
        let registry = self.registry!
        let atHello = try XCTUnwrap(registry.device(id: pairing.deviceID)?.lastSeenAt)
        XCTAssertEqual(server.connectedDeviceIDs, [pairing.deviceID])

        try await Task.sleep(nanoseconds: 60_000_000)
        _ = try await session.status(["x"])
        let afterRequest = try XCTUnwrap(registry.device(id: pairing.deviceID)?.lastSeenAt)
        XCTAssertGreaterThan(afterRequest, atHello)

        await session.close()
        let gone = await eventually { server.connectedDeviceIDs.isEmpty }
        XCTAssertTrue(gone, "the device still counts as connected")
        // …and the disconnect wrote the last contact down for the next launch.
        let reloaded = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        let stored = try XCTUnwrap(reloaded.device(id: pairing.deviceID)?.lastSeenAt)
        XCTAssertEqual(stored.timeIntervalSince1970, afterRequest.timeIntervalSince1970, accuracy: 1)
    }

    func testConnectedDevicesAgreeWithTheDisconnectEvent() async throws {
        let server = makeServer(advertised: false)
        let seenAtDisconnect = HealthBox<Set<String>?>(nil)
        try server.start()
        let events = self.events!
        server.onEvent = { [weak server] event in
            events.append(event)
            if case .deviceDisconnected = event { seenAtDisconnect.set(server?.connectedDeviceIDs) }
        }
        let (_, session) = try await pair()
        await session.close()
        let disconnected = await eventually { seenAtDisconnect.value != nil }
        XCTAssertTrue(disconnected)
        XCTAssertEqual(seenAtDisconnect.value, [], "the event fired while the device still counted as connected")
    }

    func testContactTimesAreKeptInMemoryAndWrittenSparingly() throws {
        let url = dir.appendingPathComponent("devices.json")
        let registry = DeviceRegistry(fileURL: url)
        let invite = PairingInvite.mint(macID: registry.macID, macName: "Mac")
        registry.addPending(invite)
        let t0 = Date(timeIntervalSince1970: 1_763_571_780)
        XCTAssertTrue(registry.markPaired(deviceID: invite.deviceID, name: "iPhone", model: "iPhone17,1", now: t0))

        func stored() -> Date? { DeviceRegistry(fileURL: url).device(id: invite.deviceID)?.lastSeenAt }

        registry.noteContact(deviceID: invite.deviceID, now: t0.addingTimeInterval(5))
        XCTAssertEqual(stored(), t0.addingTimeInterval(5), "the first contact is written")
        // An upload: a chunk every few milliseconds.
        for second in 6...20 {
            registry.noteContact(deviceID: invite.deviceID, now: t0.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(registry.device(id: invite.deviceID)?.lastSeenAt, t0.addingTimeInterval(20))
        XCTAssertEqual(stored(), t0.addingTimeInterval(5), "not rewritten for every chunk")

        registry.noteContact(deviceID: invite.deviceID, now: t0.addingTimeInterval(40))
        XCTAssertEqual(stored(), t0.addingTimeInterval(40), "written again once the interval passed")

        registry.noteContact(deviceID: invite.deviceID, now: t0.addingTimeInterval(41))
        registry.flushContacts()
        XCTAssertEqual(stored(), t0.addingTimeInterval(41), "a closing connection writes what is pending")

        registry.noteContact(deviceID: "nobody", now: t0)  // unknown device: ignored
        XCTAssertNil(registry.device(id: "nobody"))
    }

    // MARK: retry from the phone

    /// The phone's Retry for a recording the Mac failed did nothing: the Mac
    /// answered the re-offer `skip` and the next `status` was still `failed`.
    func testOfferingAFailedRecordingAgainAsksTheMacToRetry() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        let (pairing, session) = try await pair()
        let (manifest, url) = try syntheticRecording()
        delegate.setStatus(RemoteStatus(recordingID: manifest.id, state: .failed, detail: "could not decode"))

        let status = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        XCTAssertEqual(delegate.retryRequests.map(\.0), [manifest.id])
        XCTAssertEqual(delegate.retryRequests.first?.1, pairing.deviceID)
        XCTAssertEqual(status.state, .queued, "the phone must see a state it keeps polling")
        XCTAssertTrue(delegate.received.isEmpty, "the Mac has the audio; nothing is sent again")
        await session.close()
    }

    func testOfferingAFinishedRecordingAgainIsNotARetry() async throws {
        let server = makeServer(advertised: false)
        try server.start()
        let (_, session) = try await pair()
        for state in [RemoteState.queued, .transcribing, .transcribed, .received] {
            let (manifest, url) = try syntheticRecording()
            delegate.setStatus(RemoteStatus(recordingID: manifest.id, state: state))
            let status = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
            XCTAssertEqual(status.state, state)
        }
        XCTAssertTrue(delegate.retryRequests.isEmpty)
        XCTAssertTrue(delegate.received.isEmpty)
        await session.close()
    }

    /// A delegate that cannot retry (the default) leaves the failure alone.
    func testARetryTheMacDeclinesStaysFailed() async throws {
        let server = makeServer(advertised: false)
        delegate.retries = false
        try server.start()
        let (_, session) = try await pair()
        let (manifest, url) = try syntheticRecording()
        delegate.setStatus(RemoteStatus(recordingID: manifest.id, state: .failed, detail: "could not decode"))
        let status = try await session.upload(manifest: manifest, fileURL: url) { _, _ in }
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.detail, "could not decode")
        await session.close()
    }

    private func syntheticRecording() throws -> (RecordingManifest, URL) {
        let id = UUID().uuidString
        let url = dir.appendingPathComponent("\(id).m4a")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        let manifest = try RecordingManifest.make(
            id: id, title: "Synthetic", startedAt: Date(timeIntervalSince1970: 1_763_571_780),
            durationSeconds: 3, fileURL: url, sampleRate: 48_000, channels: 1,
            timeZone: TimeZone(identifier: "UTC")!, deviceName: "iPhone de Teste")
        return (manifest, url)
    }

    // MARK: the real thing

    func testARealAdvertIsConfirmedAndVisibleToABrowse() async throws {
        if ProcessInfo.processInfo.environment["HUSKE_SKIP_BONJOUR_TESTS"] == "1" {
            throw XCTSkip("HUSKE_SKIP_BONJOUR_TESTS=1")
        }
        let server = makeServer(advertised: true)
        server.simulatesAdvertRegistration = false
        server.advertGrace = 30
        try server.start()
        let ready = await server.waitUntilReady()
        let port = try XCTUnwrap(ready)
        let confirmed = await eventually(15) { server.health == .listening(port: port) }
        XCTAssertTrue(confirmed, "the system never confirmed the advert: \(server.health)")

        let visible = await SyncServer.advertIsVisible(macID: registry.macID, timeout: 8)
        XCTAssertEqual(visible, true)
        let stranger = await SyncServer.advertIsVisible(macID: UUID().uuidString, timeout: 1.5)
        XCTAssertEqual(stranger, false, "a Mac that is not there must read as not visible, not as unknown")
    }
}

// MARK: - test doubles

final class HealthLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [SyncServerHealth] = []
    func append(_ health: SyncServerHealth) { lock.withLock { _values.append(health) } }
    var values: [SyncServerHealth] { lock.withLock { _values } }
}

final class HealthBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    func set(_ value: Value) { lock.withLock { _value = value } }
    var value: Value { lock.withLock { _value } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

/// Holds a TCP port the way some other process would, until `release()`.
final class PortSquatter {
    let port: UInt16
    private var descriptor: Int32

    init() throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SyncError.network(.other("socket() failed")) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw SyncError.network(.other("could not hold a port"))
        }
        var actual = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin6_port)
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// A delegate whose engine can be asked to try a failed recording again.
final class RetryingDelegate: SyncServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: RemoteStatus] = [:]
    private var _received: [String] = []
    private var _retryRequests: [(String, String)] = []
    var retries = true

    var received: [String] { lock.withLock { _received } }
    var retryRequests: [(String, String)] { lock.withLock { _retryRequests } }
    func setStatus(_ status: RemoteStatus) { lock.withLock { statuses[status.recordingID] = status } }

    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        try? FileManager.default.removeItem(at: fileURL)
        let status = RemoteStatus(recordingID: manifest.id, state: .queued)
        lock.withLock {
            _received.append(manifest.id)
            statuses[manifest.id] = status
        }
        return status
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        lock.withLock { recordingIDs.map { statuses[$0] ?? .unknown($0) } }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? { nil }
    func syncServerDevicesChanged(_ server: SyncServer) {}
    func syncServerEngineAvailable(_ server: SyncServer) -> Bool { true }

    func syncServer(
        _ server: SyncServer, retryRequestedFor recordingID: String, from device: PairedDevice
    ) async -> RemoteStatus? {
        lock.withLock {
            _retryRequests.append((recordingID, device.deviceID))
            guard retries else { return nil }
            let status = RemoteStatus(recordingID: recordingID, state: .queued, detail: "Trying again")
            statuses[recordingID] = status
            return status
        }
    }
}
