// Test support for failure tests: a loopback relay that misbehaves like a bad
// network, and the server-on-loopback fixture those tests share.

import CryptoKit
import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

/// A plain-TCP relay between a `SyncClient` and a `SyncServer` on loopback
/// that can misbehave on demand. It never holds a key, so like the network it
/// sees only TLS ciphertext: whatever it does to the bytes, the two ends have
/// to cope with through TLS and the protocol.
///
/// Byte counts are per connection and count client → server ("up") traffic
/// from the first byte of the TLS handshake. All state lives on `queue`.
final class FaultProxy: @unchecked Sendable {
    enum Fault: Sendable, Equatable {
        case none
        /// Accept the TCP connection, then never forward or answer a byte.
        case blackhole
        /// Deliver exactly `afterUpBytes` to the server, then nothing more in
        /// either direction — not even a close. Both sockets stay open: the
        /// link went quiet and neither end is told (out of Wi-Fi range, a
        /// sleeping peer). The connection stays dead once the fault is lifted.
        case stall(afterUpBytes: Int)
        /// Deliver exactly `afterUpBytes` to the server, then close both TCP
        /// connections with no TLS goodbye: the link died and both ends hear
        /// of it (a router reset, the peer's process killed).
        case sever(afterUpBytes: Int)
        /// Flip one byte inside the first TLS application-data record that
        /// starts at or after `afterUpBytes`: one damaged record, exactly.
        case corruptRecord(afterUpBytes: Int)
        /// The same for the other direction: damage the next application-data
        /// record the server sends (its next reply).
        case corruptReplyRecord
    }

    private let listener: NWListener
    private let target: NWEndpoint
    private let queue = DispatchQueue(label: "huske.test.fault-proxy")
    private var _fault: Fault = .none
    private var _latency: TimeInterval = 0
    private var links: [Link] = []
    private var _corruptedRecords = 0

    init(targetPort: UInt16) throws {
        target = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!)
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        listener.start(queue: queue)
    }

    /// What goes wrong from now on, for open connections too — except that a
    /// connection that stalled or was severed stays that way.
    var fault: Fault {
        get { queue.sync { _fault } }
        set { queue.sync { _fault = newValue } }
    }

    /// One-way delay added to every forwarded read, in both directions.
    var latency: TimeInterval {
        get { queue.sync { _latency } }
        set { queue.sync { _latency = newValue } }
    }

    /// How many records have been damaged so far.
    var corruptedRecords: Int { queue.sync { _corruptedRecords } }

    func waitForPort() async throws -> UInt16 {
        for _ in 0..<500 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SyncError.timeout
    }

    /// Close every open connection now, with no TLS goodbye.
    func severAll() {
        queue.sync {
            for link in links { link.sever() }
            links.removeAll()
        }
    }

    func stop() {
        listener.cancel()
        severAll()
    }

    // MARK: relay (everything below runs on `queue`)

    private final class Link: @unchecked Sendable {
        let client: NWConnection
        let server: NWConnection?
        var upBytes = 0
        var cut = false
        var stalled = false
        var records = TLSRecordScanner()
        var replyRecords = TLSRecordScanner()
        /// Where in the server → client stream `corruptReplyRecord` was armed.
        var replyThreshold: Int?
        /// Reads waiting out `latency`, per direction, in arrival order.
        var delayed: [Bool: [(due: DispatchTime, data: Data)]] = [true: [], false: []]

        init(client: NWConnection, server: NWConnection?) {
            self.client = client
            self.server = server
        }

        /// A TCP close on both sides. Deliberately not `forceCancel()`: on
        /// loopback that sometimes drops the socket without the peer's
        /// kernel seeing a FIN or RST, which is `stall`'s job.
        func sever() {
            cut = true
            client.cancel()
            server?.cancel()
        }
    }

    private func accept(_ inbound: NWConnection) {
        if _fault == .blackhole {
            // Complete the TCP handshake and say nothing, ever.
            let link = Link(client: inbound, server: nil)
            links.append(link)
            inbound.start(queue: queue)
            return
        }
        let outbound = NWConnection(to: target, using: .tcp)
        let link = Link(client: inbound, server: outbound)
        links.append(link)
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(link, up: true)
        pump(link, up: false)
    }

    private func pump(_ link: Link, up: Bool) {
        guard let server = link.server else { return }
        let source = up ? link.client : server
        let sink = up ? server : link.client
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !link.cut else { return }
            if let data, !data.isEmpty, !link.stalled {
                guard let forwarded = up ? self.applyFault(to: data, on: link) : self.applyReplyFault(to: data, on: link)
                else {
                    return  // severed
                }
                if !forwarded.isEmpty { self.forward(forwarded, on: link, up: up, to: sink) }
            }
            if isComplete || error != nil {
                // One side closed: pass that on, after anything still delayed
                // — unless the link is stalled, where nothing gets through.
                self.queue.asyncAfter(deadline: .now() + self._latency) {
                    guard !link.cut, !link.stalled else { return }
                    for pending in link.delayed[up] ?? [] {
                        sink.send(content: pending.data, completion: .idempotent)
                    }
                    link.delayed[up] = []
                    sink.send(
                        content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in sink.cancel() })
                }
                return
            }
            self.pump(link, up: up)
        }
    }

    /// The bytes of `data` to deliver upstream, or nil once the link is cut.
    private func applyFault(to data: Data, on link: Link) -> Data? {
        let start = link.upBytes
        link.upBytes += data.count
        switch _fault {
        case .none, .blackhole:
            link.records.skip(data)
            return data
        case .corruptReplyRecord:
            link.records.skip(data)
            return data
        case .stall(let limit):
            guard link.upBytes > limit else { return data }
            link.stalled = true
            return Data(data.prefix(max(0, limit - start)))
        case .sever(let limit):
            guard link.upBytes > limit else { return data }
            let last = Data(data.prefix(max(0, limit - start)))
            link.cut = true
            link.server?.send(content: last, completion: .contentProcessed { _ in link.sever() })
            return nil
        case .corruptRecord(let limit):
            var damaged = data
            if link.records.flipOneByte(in: &damaged, recordsStartingAtOrAfter: limit) {
                _corruptedRecords += 1
            }
            return damaged
        }
    }

    /// The server → client bytes to deliver.
    private func applyReplyFault(to data: Data, on link: Link) -> Data {
        guard _fault == .corruptReplyRecord else {
            link.replyRecords.skip(data)
            return data
        }
        let threshold = link.replyThreshold ?? link.replyRecords.offset
        link.replyThreshold = threshold
        var damaged = data
        if link.replyRecords.flipOneByte(in: &damaged, recordsStartingAtOrAfter: threshold) {
            _corruptedRecords += 1
        }
        return damaged
    }

    private func forward(_ data: Data, on link: Link, up: Bool, to sink: NWConnection) {
        guard _latency > 0 else {
            sink.send(content: data, completion: .idempotent)
            return
        }
        // A FIFO per direction: two timers with nearly equal deadlines must
        // not be able to swap two reads.
        let due = DispatchTime.now() + _latency
        link.delayed[up, default: []].append((due, data))
        queue.asyncAfter(deadline: due) {
            let now = DispatchTime.now()
            while let next = link.delayed[up]?.first, next.due <= now {
                link.delayed[up]?.removeFirst()
                if !link.cut, !link.stalled { sink.send(content: next.data, completion: .idempotent) }
            }
        }
    }
}

/// Follows TLS record framing (`type(1) version(2) length(2) body`) through a
/// byte stream delivered in arbitrary pieces, so a fault can land inside one
/// chosen record rather than on a length field by accident.
struct TLSRecordScanner {
    private static let applicationData: UInt8 = 23
    /// Bytes of the stream seen so far.
    private(set) var offset = 0
    private var header: [UInt8] = []
    private var bodyLength = 0
    private var bodyRemaining = 0
    /// Index within the current record's body of the byte to flip.
    private var target: Int?
    private var done = false

    mutating func skip(_ data: Data) {
        var copy = data
        _ = scan(&copy, threshold: nil)
    }

    /// Flips one byte in the middle of the first application-data record that
    /// starts at or after stream offset `threshold`. True once, when it does.
    mutating func flipOneByte(in data: inout Data, recordsStartingAtOrAfter threshold: Int) -> Bool {
        scan(&data, threshold: threshold)
    }

    private mutating func scan(_ data: inout Data, threshold: Int?) -> Bool {
        var flipped = false
        var index = 0
        while index < data.count {
            if bodyRemaining == 0 {
                header.append(data[data.startIndex + index])
                index += 1
                offset += 1
                guard header.count == 5 else { continue }
                bodyLength = Int(header[3]) << 8 | Int(header[4])
                bodyRemaining = bodyLength
                let recordStart = offset - 5
                if let threshold, !done, target == nil, header[0] == Self.applicationData,
                    recordStart >= threshold, bodyLength > 0
                {
                    target = bodyLength / 2
                }
                header.removeAll(keepingCapacity: true)
            } else {
                let take = min(bodyRemaining, data.count - index)
                let consumed = bodyLength - bodyRemaining
                if let wanted = target, wanted >= consumed, wanted < consumed + take {
                    data[data.startIndex + index + (wanted - consumed)] ^= 0xFF
                    target = nil
                    done = true
                    flipped = true
                }
                index += take
                offset += take
                bodyRemaining -= take
            }
        }
        return flipped
    }
}

// MARK: - fixture

/// One real `SyncServer` on loopback, with the helpers failure tests share.
final class SyncHarness: @unchecked Sendable {
    let dir: URL
    let registry: DeviceRegistry
    let server: SyncServer
    /// What `receiver` is unless a test brought its own.
    let delegate = FakeDelegate()
    /// The server's delegate (it holds it weakly, so it is kept here).
    let receiver: any SyncServerDelegate
    let events = EventLog()
    /// How `client(_:)` sizes upload chunks. Tests that place a fault at a
    /// chunk boundary pin it; the rest run as the app does.
    var chunking: UploadChunking = .adaptive

    init(advertise: Bool = false, receiver: (any SyncServerDelegate)? = nil) async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registry = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        server = SyncServer(
            registry: registry, stagingDirectory: dir.appendingPathComponent("staging"),
            macName: advertise ? "Huske Test \(UUID().uuidString.prefix(6))" : "Test Mac",
            serverVersion: "test")
        self.receiver = receiver ?? delegate
        server.delegate = self.receiver
        server.advertisesService = advertise
        let events = self.events
        server.onEvent = { events.append($0) }
        if ProcessInfo.processInfo.environment["HUSKE_SYNC_TEST_LOG"] == "1" {
            server.logHandler = { print("[server] \($0)") }
        }
        try server.start()
        _ = try await port()
    }

    func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func port() async throws -> UInt16 {
        let port = await server.waitUntilReady()
        return try XCTUnwrap(port, "listener not ready")
    }

    static func loopback(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    /// A client for `pairing`, straight at the server or at `port` (a proxy).
    func client(
        _ pairing: PairedMac, port: UInt16? = nil,
        requestTimeout: TimeInterval = SyncSession.requestTimeout,
        installID: String? = nil, capabilities: [String] = SyncConstants.capabilities,
        chunking: UploadChunking? = nil
    ) async throws -> SyncClient {
        let resolved: UInt16
        if let port { resolved = port } else { resolved = try await self.port() }
        return SyncClient(
            pairing: pairing, deviceName: "iPhone de Teste", deviceModel: "iPhone17,1",
            appVersion: "1.0", endpoint: Self.loopback(resolved), requestTimeout: requestTimeout,
            installID: installID, capabilities: capabilities, chunking: chunking ?? self.chunking)
    }

    /// A phone that has already paired (its first connection made and closed).
    func pairedPhone() async throws -> PairedMac {
        let pairing = PairedMac(invite: server.makeInvite())
        let before = disconnects
        let session = try await client(pairing).connect(timeout: 5)
        await session.close()
        _ = await eventually(3) { self.disconnects > before }
        return pairing
    }

    /// A raw, handshaken connection for `pairing`: for tests that speak the
    /// wire by hand.
    func rawConnection(_ pairing: PairedMac) async throws -> FramedConnection {
        let framed = FramedConnection(
            NWConnection(
                to: Self.loopback(try await port()),
                using: TLSPSK.clientParameters(identity: pairing.deviceID, key: pairing.key)),
            label: "raw")
        try await framed.start(timeout: 5)
        return framed
    }

    func recording(bytes count: Int, id: String = UUID().uuidString) throws -> (RecordingManifest, URL, Data) {
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

    /// Bytes the server has staged for an unfinished upload.
    func stagedBytes(_ id: String) -> Data? {
        try? Data(contentsOf: server.stagingDirectory.appendingPathComponent("\(id).part"))
    }

    var disconnects: Int {
        events.values.filter { if case .deviceDisconnected = $0 { return true } else { return false } }.count
    }

    /// Exactly one copy of `data` reached the delegate, and it hashes to what
    /// the manifest promised.
    func assertCommittedOnce(
        _ manifest: RecordingManifest, _ data: Data, file: StaticString = #filePath, line: UInt = #line
    ) {
        let copies = delegate.received.filter { $0.0.id == manifest.id }
        XCTAssertEqual(copies.count, 1, "handed to the engine exactly once", file: file, line: line)
        XCTAssertEqual(copies.first?.1, data, file: file, line: line)
        XCTAssertEqual(
            copies.first.map { SHA256.hash(data: $0.1).hexString }, manifest.sha256, file: file, line: line)
    }
}

/// Polls `condition` until true or `timeout`.
func eventually(_ timeout: TimeInterval, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Runs `body`, returning how long it took and what it threw.
func outcome<T: Sendable>(
    of body: @Sendable () async throws -> T
) async -> (seconds: TimeInterval, result: Result<T, Error>) {
    let started = Date()
    do {
        let value = try await body()
        return (Date().timeIntervalSince(started), .success(value))
    } catch {
        return (Date().timeIntervalSince(started), .failure(error))
    }
}

extension Result where Failure == Error {
    var syncError: SyncError? {
        if case .failure(let error) = self { return error as? SyncError }
        return nil
    }
}

/// A delegate whose hand-off waits until the test says go, so a test can act
/// while a recording is in the middle of being handed to the engine. Like the
/// Mac's real receiver it takes the file away.
final class GatedReceiver: SyncServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _handOffs: [String] = []
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Recording IDs in the order their hand-off began.
    var handOffs: [String] { lock.withLock { _handOffs } }

    /// Lets every waiting (and future) hand-off finish.
    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        lock.withLock { _handOffs.append(manifest.id) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
        try? FileManager.default.removeItem(at: fileURL)
        return RemoteStatus(recordingID: manifest.id, state: .queued, detail: "in the inbox")
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        recordingIDs.map { .unknown($0) }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? { nil }
    func syncServerDevicesChanged(_ server: SyncServer) {}
    func syncServerEngineAvailable(_ server: SyncServer) -> Bool { true }
}

/// A one-shot latch: `wait()` suspends until `open()`; `arrivals` counts who
/// got there.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var _arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var arrivals: Int { lock.withLock { _arrivals } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                _arrivals += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}
