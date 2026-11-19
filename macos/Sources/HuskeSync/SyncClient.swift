// iPhone side: find the paired Mac on Bonjour (TXT `mac` = its macID),
// connect with TLS-PSK, `hello`, then strict request → response.

import Foundation
import Network

// MARK: - Bonjour

enum BonjourBrowsing {
    static func parameters() -> NWParameters {
        let params = NWParameters()
        params.includePeerToPeer = true
        return params
    }

    static func descriptor() -> NWBrowser.Descriptor {
        .bonjourWithTXTRecord(type: SyncConstants.serviceType, domain: nil)
    }

    static func macID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata {
            return txt["mac"]
        }
        return nil
    }

    /// Browses until a service advertising `macID` shows up.
    static func find(macID wanted: String, timeout: TimeInterval) async throws -> NWEndpoint {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var continuation: CheckedContinuation<NWEndpoint, Error>?
            func finish(_ result: Result<NWEndpoint, Error>) {
                lock.lock()
                let c = continuation
                continuation = nil
                lock.unlock()
                c?.resume(with: result)
            }
        }
        let state = State()
        let queue = DispatchQueue(label: "huske.sync.browse")
        let browser = NWBrowser(for: descriptor(), using: parameters())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            if Task.isCancelled {
                state.finish(.failure(CancellationError()))
                return
            }
            browser.browseResultsChangedHandler = { results, _ in
                if let match = results.first(where: { macID(of: $0) == wanted }) {
                    browser.cancel()
                    state.finish(.success(match.endpoint))
                }
            }
            browser.stateUpdateHandler = { browserState in
                if case .failed(let error) = browserState {
                    browser.cancel()
                    state.finish(.failure(SyncError.io("Bonjour browse failed: \(error)")))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                state.finish(.failure(SyncError.macNotFound))
            }
            browser.start(queue: queue)
            }
        } onCancel: {
            // A superseded attempt (e.g. re-pairing) must not sit out its timeout.
            browser.cancel()
            state.finish(.failure(CancellationError()))
        }
    }
}

// MARK: - presence

/// Watches Bonjour for one paired Mac. `isReachable` drives the UI dot and
/// triggers uploads.
public final class MacPresenceMonitor: @unchecked Sendable {
    private let macID: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "huske.sync.presence")
    private var browser: NWBrowser?
    private var reachable = false
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(macID: String) {
        self.macID = macID
    }

    deinit {
        browser?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    public func start() {
        lock.lock()
        guard browser == nil else {
            lock.unlock()
            return
        }
        let browser = NWBrowser(for: BonjourBrowsing.descriptor(), using: BonjourBrowsing.parameters())
        self.browser = browser
        lock.unlock()
        let macID = self.macID
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.set(results.contains { BonjourBrowsing.macID(of: $0) == macID })
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.set(false)
            default: break
            }
        }
        browser.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let browser = self.browser
        self.browser = nil
        lock.unlock()
        browser?.cancel()
        set(false)
    }

    /// Emits whenever reachability changes (current value first).
    public var updates: AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            let current = reachable
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public var isReachable: Bool {
        lock.withLock { reachable }
    }

    private func set(_ value: Bool) {
        lock.lock()
        guard value != reachable else {
            lock.unlock()
            return
        }
        reachable = value
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(value) }
    }
}

// MARK: - client

public final class SyncClient: Sendable {
    private enum Target: Sendable {
        case bonjour
        case endpoint(NWEndpoint)
    }

    private let pairing: PairedMac
    private let deviceName: String
    private let deviceModel: String
    private let appVersion: String
    private let target: Target

    public init(pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.target = .bonjour
    }

    /// Test hook: connect to an explicit endpoint (e.g. 127.0.0.1:port)
    /// instead of resolving the paired Mac through Bonjour.
    @_spi(Testing)
    public init(
        pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String,
        endpoint: NWEndpoint
    ) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.target = .endpoint(endpoint)
    }

    /// Browse for the paired Mac (≤ `timeout`), connect with TLS-PSK, send hello.
    public func connect(timeout: TimeInterval = 8) async throws -> SyncSession {
        let deadline = Date().addingTimeInterval(timeout)
        let endpoint: NWEndpoint
        switch target {
        case .endpoint(let explicit):
            endpoint = explicit
        case .bonjour:
            endpoint = try await BonjourBrowsing.find(macID: pairing.macID, timeout: timeout)
        }
        let remaining = max(deadline.timeIntervalSinceNow, 3)
        let params = TLSPSK.clientParameters(identity: pairing.deviceID, key: pairing.key)
        let connection = FramedConnection(
            NWConnection(to: endpoint, using: params), label: "client")
        do {
            try await connection.start(timeout: remaining)
        } catch {
            connection.cancel()
            throw error
        }
        let hello = HelloMessage(
            protocolVersion: SyncConstants.protocolVersion,
            deviceID: pairing.deviceID,
            deviceName: deviceName,
            deviceModel: deviceModel,
            appVersion: appVersion)
        do {
            try await connection.send(.hello(hello))
            guard let reply = try await connection.receive(timeout: max(deadline.timeIntervalSinceNow, 5))
            else { throw SyncError.connectionClosed }
            switch reply {
            case .welcome(let welcome):
                guard welcome.macID == pairing.macID else {
                    throw SyncError.protocolError(
                        code: "wrong_mac", message: "connected to a different Mac")
                }
                return SyncSession(connection: connection, welcome: welcome)
            case .error(let error):
                throw SyncSession.map(error)
            default:
                throw SyncError.protocolError(
                    code: ErrorCode.badRequest.rawValue, message: "expected welcome, got \(reply.type)")
            }
        } catch SyncError.connectionClosed {
            connection.cancel()
            // A TLS-PSK rejection on the Mac (forgotten device, wrong key)
            // often surfaces here as the socket closing before any `welcome`.
            throw SyncError.handshakeFailed(
                "the Mac closed the connection before accepting this iPhone — it may have been unpaired")
        } catch {
            connection.cancel()
            throw error
        }
    }
}

// MARK: - session

/// Serializes requests: the protocol allows one outstanding request.
private actor RequestGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public final class SyncSession: Sendable {
    public let welcome: Welcome
    let connection: FramedConnection
    private let gate = RequestGate()

    /// Per-request reply timeout.
    static let requestTimeout: TimeInterval = 30

    init(connection: FramedConnection, welcome: Welcome) {
        self.connection = connection
        self.welcome = welcome
    }

    /// Offer → (resume from offset | skip) → chunks → commit.
    /// `progress(sent, total)` is called on an arbitrary queue.
    public func upload(
        manifest: RecordingManifest, fileURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> RemoteStatus {
        let total = manifest.byteCount
        let offerReply = try await request(.offer(OfferMessage(recording: manifest)))
        guard case .offerReply(let offer) = offerReply, offer.recordingID == manifest.id else {
            throw Self.unexpected(offerReply, expected: "offerReply")
        }
        if offer.action == .skip {
            progress(total, total)
            let statuses = try await status([manifest.id])
            return statuses.first { $0.recordingID == manifest.id }
                ?? RemoteStatus(recordingID: manifest.id, state: .received)
        }
        guard offer.offset >= 0, offer.offset <= total else {
            throw SyncError.protocolError(
                code: ErrorCode.badRequest.rawValue, message: "offset \(offer.offset) out of range")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw SyncError.io("cannot read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var offset = offer.offset
        var resyncs = 0
        progress(offset, total)
        while offset < total {
            let length = Int(min(Int64(SyncConstants.chunkSize), total - offset))
            let body: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                body = try handle.read(upToCount: length) ?? Data()
            } catch {
                throw SyncError.io("read failed: \(error.localizedDescription)")
            }
            guard !body.isEmpty else {
                throw SyncError.io("\(fileURL.lastPathComponent) is shorter than its manifest")
            }
            let reply = try await request(
                .chunk(ChunkMessage(recordingID: manifest.id, offset: offset), body: body),
                passErrors: true)
            switch reply {
            case .chunkAck(let ack):
                guard ack.received >= 0, ack.received <= total else {
                    throw SyncError.protocolError(
                        code: ErrorCode.badRequest.rawValue, message: "ack \(ack.received) out of range")
                }
                offset = ack.received
            case .error(let error) where error.code == ErrorCode.offsetMismatch.rawValue:
                // Another connection (an older one still draining) moved the
                // file on; continue from what the Mac actually holds.
                resyncs += 1
                guard let received = error.received, resyncs <= 5, received >= 0, received <= total
                else { throw Self.map(error) }
                offset = received
            case .error(let error):
                throw Self.map(error)
            default:
                throw Self.unexpected(reply, expected: "chunkAck")
            }
            progress(offset, total)
        }

        let commitReply = try await request(.commit(CommitMessage(recordingID: manifest.id)))
        guard case .committed(let committed) = commitReply else {
            throw Self.unexpected(commitReply, expected: "committed")
        }
        return committed.status
    }

    public func status(_ recordingIDs: [String]) async throws -> [RemoteStatus] {
        let reply = try await request(.status(StatusRequestMessage(recordingIDs: recordingIDs)))
        guard case .statusReply(let status) = reply else {
            throw Self.unexpected(reply, expected: "statusReply")
        }
        return status.items
    }

    public func transcript(_ recordingID: String) async throws -> String? {
        let reply = try await request(.transcript(TranscriptRequestMessage(recordingID: recordingID)))
        guard case .transcriptReply(let header, let body) = reply,
            header.recordingID == recordingID
        else { throw Self.unexpected(reply, expected: "transcriptReply") }
        guard header.available else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    public func close() async {
        await gate.acquire()
        if !connection.isClosed {
            try? await connection.send(.bye, timeout: 2)
        }
        connection.cancel()
        await gate.release()
    }

    // MARK: plumbing

    private func request(_ message: WireMessage, passErrors: Bool = false) async throws -> WireMessage {
        await gate.acquire()
        let reply: WireMessage
        do {
            try await connection.send(message, timeout: Self.requestTimeout)
            guard let received = try await connection.receive(timeout: Self.requestTimeout) else {
                throw SyncError.connectionClosed
            }
            reply = received
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        if !passErrors, case .error(let error) = reply {
            throw Self.map(error)
        }
        return reply
    }

    static func map(_ error: ErrorMessage) -> SyncError {
        if error.code == ErrorCode.checksumMismatch.rawValue { return .checksumMismatch }
        return .protocolError(code: error.code, message: error.message)
    }

    private static func unexpected(_ message: WireMessage, expected: String) -> SyncError {
        if case .error(let error) = message { return map(error) }
        return .protocolError(
            code: ErrorCode.badRequest.rawValue, message: "expected \(expected), got \(message.type)")
    }
}
