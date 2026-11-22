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

    /// How long the attempt on the resolved address may take before the
    /// service endpoint gets its turn. A TLS connection on a local network
    /// is up in milliseconds.
    static let directAttemptLimit: TimeInterval = 3

    /// A started (TLS established) connection to `endpoint`, by `deadline`.
    ///
    /// A service endpoint hides a rejected key and a refused port (see
    /// `resolve`), so the address behind it is tried first: there the Mac's
    /// "no" arrives at once and is the answer. Only when that address gives
    /// *no* answer (no path, or nothing within `directLimit`) — or the name
    /// didn't resolve — does the service endpoint itself get the rest of the
    /// time: Network.framework then tries every address the Mac has, which is
    /// slower to say why but connects whenever anything can.
    static func openConnection(
        to endpoint: NWEndpoint, deadline: Date, parameters: () -> NWParameters,
        directLimit: TimeInterval = BonjourBrowsing.directAttemptLimit,
        resolve: (NWEndpoint, TimeInterval) async -> NWEndpoint? = BonjourBrowsing.resolve
    ) async throws -> FramedConnection {
        let address = await resolve(endpoint, min(2, max(deadline.timeIntervalSinceNow / 2, 0.5)))
        try Task.checkCancellation()
        if let address, address != endpoint {
            let direct = FramedConnection(NWConnection(to: address, using: parameters()), label: "client")
            do {
                try await direct.start(timeout: min(directLimit, max(deadline.timeIntervalSinceNow, 1)))
                return direct
            } catch {
                direct.cancel()
                guard direct.gotNoAnswer, !Task.isCancelled else { throw error }
            }
        }
        let connection = FramedConnection(NWConnection(to: endpoint, using: parameters()), label: "client")
        do {
            try await connection.start(timeout: max(deadline.timeIntervalSinceNow, 3))
            return connection
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// The address behind a Bonjour service endpoint (other endpoints come
    /// back as they are), or nil if it didn't resolve in `timeout`. A UDP
    /// "connection" resolves the name and becomes ready without putting a
    /// packet on the wire.
    ///
    /// Why: a TLS connection to a *service* endpoint that the Mac rejects
    /// (unknown or wrong key) or refuses never says so. Network.framework
    /// keeps it "preparing", in case another address works, until the
    /// caller's timeout — a forgotten key then read as "took too long". A
    /// connection to a concrete address reports the rejection at once.
    static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> NWEndpoint? {
        guard case .service = endpoint else { return endpoint }
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var continuation: CheckedContinuation<NWEndpoint?, Never>?
            var finished = false
            func finish(_ result: NWEndpoint?) {
                lock.lock()
                let c = continuation
                continuation = nil
                finished = true
                lock.unlock()
                c?.resume(returning: result)
            }
        }
        let state = State()
        let queue = DispatchQueue(label: "huske.sync.resolve")
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        let resolved: NWEndpoint? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.lock.lock()
                if state.finished || Task.isCancelled {
                    state.lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                state.continuation = continuation
                state.lock.unlock()
                connection.stateUpdateHandler = { [weak connection] connectionState in
                    switch connectionState {
                    case .ready:
                        if let remote = connection?.currentPath?.remoteEndpoint, case .hostPort = remote {
                            state.finish(remote)
                        } else {
                            state.finish(nil)
                        }
                    case .failed, .cancelled:
                        state.finish(nil)
                    default:
                        // `.waiting`: the name may still resolve; `timeout` bounds it.
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { state.finish(nil) }
                connection.start(queue: queue)
            }
        } onCancel: {
            state.finish(nil)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return resolved
    }

    /// Browses until a service advertising `macID` shows up. A browser that
    /// cannot browse at all is not "Mac not found": Local Network denial fails
    /// at once with `DiscoveryIssue.localNetworkDenied`, and a browser still
    /// waiting when time runs out reports why instead of `macNotFound`.
    /// `onStart` is a test seam (it sees the browser once started).
    static func find(
        macID wanted: String, timeout: TimeInterval,
        onStart: (@Sendable (NWBrowser, DispatchQueue) -> Void)? = nil
    ) async throws -> NWEndpoint {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var continuation: CheckedContinuation<NWEndpoint, Error>?
            var waitingIssue: DiscoveryIssue?
            func finish(_ result: Result<NWEndpoint, Error>) {
                lock.lock()
                let c = continuation
                continuation = nil
                lock.unlock()
                c?.resume(with: result)
            }
            func setWaiting(_ issue: DiscoveryIssue?) { lock.withLock { waitingIssue = issue } }
            var currentIssue: DiscoveryIssue? { lock.withLock { waitingIssue } }
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
                switch browserState {
                case .failed(let error):
                    browser.cancel()
                    let issue = DiscoveryIssue(error)
                    if issue == .localNetworkDenied {
                        state.finish(.failure(issue))
                    } else {
                        state.finish(.failure(SyncError.network(.nameNotResolved("Bonjour browse failed: \(error)"))))
                    }
                case .waiting(let error):
                    let issue = DiscoveryIssue(error)
                    if issue == .localNetworkDenied {
                        // Will not change until the user flips the switch.
                        browser.cancel()
                        state.finish(.failure(issue))
                    } else {
                        state.setWaiting(issue)
                    }
                case .ready:
                    state.setWaiting(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                state.finish(.failure(state.currentIssue ?? SyncError.macNotFound))
            }
            browser.start(queue: queue)
            onStart?(browser, queue)
            }
        } onCancel: {
            // A superseded attempt (e.g. re-pairing) must not sit out its timeout.
            browser.cancel()
            state.finish(.failure(CancellationError()))
        }
    }
}

// MARK: - link

/// How the phone sees, or reaches, the Mac.
public enum SyncRoute: String, Sendable, Hashable, CaseIterable {
    /// The Wi-Fi network both are on.
    case wifi
    case wired
    /// Straight between the two devices (peer-to-peer Wi-Fi, as AirDrop
    /// uses): no shared network needed.
    case peerToPeer
    case loopback
    case other

    /// AWDL and its low-latency sibling report a generic interface type; the
    /// name is what tells them apart.
    init(interfaceName name: String, type: NWInterface.InterfaceType) {
        if name.hasPrefix("awdl") || name.hasPrefix("llw") {
            self = .peerToPeer
            return
        }
        switch type {
        case .wifi: self = .wifi
        case .wiredEthernet: self = .wired
        case .loopback: self = .loopback
        default: self = .other
        }
    }

    /// The distinct routes among `interfaces`, in `allCases` order.
    static func routes(of interfaces: [NWInterface]) -> [SyncRoute] {
        let found = Set(interfaces.map { SyncRoute(interfaceName: $0.name, type: $0.type) })
        return allCases.filter(found.contains)
    }
}

/// What the Bonjour browse knows about the paired Mac at one moment.
public struct MacPresence: Sendable, Equatable {
    /// The monitor was asked to look (`start()` without a later `stop()`).
    public let isBrowsing: Bool
    /// Why it cannot look right now; nil while browsing works.
    public let issue: DiscoveryIssue?
    /// The paired Mac's service while it is visible. Hand it to
    /// `SyncClient.connect(to:)`, which then skips a second browse.
    public let endpoint: NWEndpoint?
    /// The ways the Mac was seen (same Wi-Fi, peer-to-peer…).
    public let routes: [SyncRoute]

    public var isVisible: Bool { endpoint != nil }

    public init(
        isBrowsing: Bool = false, issue: DiscoveryIssue? = nil,
        endpoint: NWEndpoint? = nil, routes: [SyncRoute] = []
    ) {
        self.isBrowsing = isBrowsing
        self.issue = issue
        self.endpoint = endpoint
        self.routes = routes
    }
}

extension SyncSession {
    /// How this session reaches the Mac: the Wi-Fi both are on, or directly
    /// (peer-to-peer). For the UI ("Connected over Wi-Fi").
    public var route: SyncRoute { connection.route }
}

// MARK: - presence

/// Watches Bonjour for one paired Mac. `isReachable` drives the UI dot and
/// triggers uploads. A browser that fails (iOS tears down the mDNSResponder
/// connection of a suspended app, so this happens on return from background)
/// is replaced with backoff; `issue` says why nothing can be seen meanwhile.
public final class MacPresenceMonitor: @unchecked Sendable {
    private let macID: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "huske.sync.presence")
    private var browser: NWBrowser?
    private var wantsRunning = false
    private var failures = 0
    private var reachable = false
    private var currentIssue: DiscoveryIssue?
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var issueContinuations: [UUID: AsyncStream<DiscoveryIssue?>.Continuation] = [:]
    /// Where the paired Mac was last seen (nil = not visible), and the
    /// snapshot `presenceUpdates` last delivered.
    private var sighting: (endpoint: NWEndpoint, routes: [SyncRoute])?
    private var scriptedSightings = false
    private var lastPresence = MacPresence()
    private var presenceContinuations: [UUID: AsyncStream<MacPresence>.Continuation] = [:]

    public init(macID: String) {
        self.macID = macID
    }

    deinit {
        browser?.cancel()
        for continuation in continuations.values { continuation.finish() }
        for continuation in issueContinuations.values { continuation.finish() }
        for continuation in presenceContinuations.values { continuation.finish() }
    }

    public func start() {
        lock.lock()
        wantsRunning = true
        guard browser == nil else {
            lock.unlock()
            return
        }
        let browser = NWBrowser(for: BonjourBrowsing.descriptor(), using: BonjourBrowsing.parameters())
        self.browser = browser
        lock.unlock()
        let macID = self.macID
        // Callbacks from a browser that has since been replaced or stopped
        // must not touch the state the current one reports.
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.isCurrent(browser), !self.sightingsAreScripted else { return }
            let match = results.first { BonjourBrowsing.macID(of: $0) == macID }
            self.sight(match?.endpoint, routes: match.map { SyncRoute.routes(of: $0.interfaces) } ?? [])
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser else { return }
            self.browser(browser, changedTo: state)
        }
        browser.start(queue: queue)
        publishPresence()
    }

    public func stop() {
        lock.lock()
        wantsRunning = false
        failures = 0
        let browser = self.browser
        self.browser = nil
        lock.unlock()
        browser?.cancel()
        set(false)
        setIssue(nil)
        publishPresence()
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

    /// Why the Mac cannot be looked for right now (nil while browsing works).
    public var issue: DiscoveryIssue? {
        lock.withLock { currentIssue }
    }

    /// Emits whenever `issue` changes (current value first).
    public var issueUpdates: AsyncStream<DiscoveryIssue?> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            issueContinuations[id] = continuation
            let current = currentIssue
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.issueContinuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Everything the browse knows, in one value: whether it is looking, why
    /// it can't, and — while the Mac is visible — the endpoint to connect to.
    public var presence: MacPresence {
        lock.withLock { snapshot() }
    }

    /// The paired Mac's service while it is visible (`presence.endpoint`).
    public var endpoint: NWEndpoint? {
        presence.endpoint
    }

    /// Emits whenever `presence` changes (current value first): the Mac
    /// appeared, left, or is now seen another way; the browser started,
    /// stopped, or ran into an issue.
    public var presenceUpdates: AsyncStream<MacPresence> {
        let id = UUID()
        return AsyncStream { continuation in
            // Registered and primed under the lock, so a change published
            // meanwhile can't arrive before the current value.
            lock.lock()
            presenceContinuations[id] = continuation
            continuation.yield(lastPresence)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.presenceContinuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Backoff before replacing a failed browser: 1, 2, 4, 8, 16, 30, 30… s.
    static func retryDelay(afterFailures count: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, count - 1))))
    }

    /// Test seam: deliver `state` to the current browser's handler, on its
    /// queue, as Network.framework would.
    func deliverBrowserState(_ state: NWBrowser.State) {
        guard let handler = lock.withLock({ browser?.stateUpdateHandler }) else { return }
        queue.sync { handler(state) }
    }

    /// Test seam: report the paired Mac as seen at `endpoint` (nil = gone),
    /// on the browser's queue, as a browse result would. From the first call
    /// on, real browse results are ignored, so a service that happens to be
    /// on the test machine's network can't overwrite the script.
    func deliverSighting(_ endpoint: NWEndpoint?, routes: [SyncRoute] = [.wifi]) {
        lock.withLock { scriptedSightings = true }
        queue.sync { sight(endpoint, routes: routes) }
    }

    private var sightingsAreScripted: Bool {
        lock.withLock { scriptedSightings }
    }

    /// The browse result for the paired Mac changed (nil = it is gone).
    private func sight(_ endpoint: NWEndpoint?, routes: [SyncRoute]) {
        lock.withLock { sighting = endpoint.map { ($0, routes) } }
        set(endpoint != nil)
    }

    /// Call with `lock` held. While the browser has an issue nothing it saw
    /// before can be trusted, so no endpoint is reported.
    private func snapshot() -> MacPresence {
        let seen = currentIssue == nil ? sighting : nil
        return MacPresence(
            isBrowsing: wantsRunning, issue: currentIssue,
            endpoint: seen?.endpoint, routes: seen?.routes ?? [])
    }

    private func publishPresence() {
        lock.lock()
        let now = snapshot()
        guard now != lastPresence else {
            lock.unlock()
            return
        }
        lastPresence = now
        // Yielded under the lock: two threads must not deliver out of order.
        for continuation in presenceContinuations.values { continuation.yield(now) }
        lock.unlock()
    }

    private func isCurrent(_ candidate: NWBrowser) -> Bool {
        lock.withLock { browser === candidate }
    }

    private func browser(_ source: NWBrowser, changedTo state: NWBrowser.State) {
        switch state {
        case .ready:
            guard isCurrent(source) else { return }
            lock.withLock { failures = 0 }
            setIssue(nil)
        case .waiting(let error):
            guard isCurrent(source) else { return }
            // Not browsing: whatever it reported before can't be trusted.
            setIssue(DiscoveryIssue(error))
            set(false)
        case .failed(let error):
            let delay: TimeInterval? = lock.withLock {
                guard browser === source else { return nil }
                browser = nil
                failures += 1
                return wantsRunning ? Self.retryDelay(afterFailures: failures) : nil
            }
            source.cancel()
            guard let delay else { return }
            setIssue(DiscoveryIssue(error))
            set(false)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let restart = self.lock.withLock { self.wantsRunning && self.browser == nil }
                if restart { self.start() }
            }
        case .cancelled:
            // Only our own stop() cancels the current browser, and it already
            // reported `false`; a stale browser's cancellation means nothing.
            break
        default:
            break
        }
    }

    private func set(_ value: Bool) {
        lock.lock()
        if !value { sighting = nil }
        guard value != reachable else {
            lock.unlock()
            // Still visible, but possibly somewhere else (Wi-Fi ↔ direct).
            publishPresence()
            return
        }
        reachable = value
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(value) }
        publishPresence()
    }

    private func setIssue(_ value: DiscoveryIssue?) {
        lock.lock()
        guard value != currentIssue else {
            lock.unlock()
            return
        }
        currentIssue = value
        let targets = Array(issueContinuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(value) }
        publishPresence()
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
    private let requestTimeout: TimeInterval
    private let installID: String?
    private let capabilities: [String]
    private let chunking: UploadChunking

    public init(pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.target = .bonjour
        self.requestTimeout = SyncSession.requestTimeout
        self.installID = nil
        self.capabilities = SyncConstants.capabilities
        self.chunking = .adaptive
    }

    /// - Parameters:
    ///   - installID: stable for this install of the app (`hello.installID`).
    ///     Pass it only for the pairing this iPhone keeps: the Mac removes
    ///     the install's other entries when it sees it. nil while trying a
    ///     new code next to a pairing that still works.
    ///   - capabilities: the additive features to announce; a subset of
    ///     `SyncConstants.capabilities` turns the others off.
    public init(
        pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String,
        installID: String?, capabilities: [String] = SyncConstants.capabilities
    ) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.target = .bonjour
        self.requestTimeout = SyncSession.requestTimeout
        self.installID = installID
        self.capabilities = capabilities
        self.chunking = .adaptive
    }

    /// Test hook: connect to an explicit endpoint (e.g. 127.0.0.1:port)
    /// instead of resolving the paired Mac through Bonjour. `requestTimeout`
    /// shortens the session's per-request timeout so failure tests run fast;
    /// `chunking: .fixed(n)` pins the upload chunk size so a test knows where
    /// the chunk boundaries fall.
    @_spi(Testing)
    public init(
        pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String,
        endpoint: NWEndpoint, requestTimeout: TimeInterval = SyncSession.requestTimeout,
        installID: String? = nil, capabilities: [String] = SyncConstants.capabilities,
        chunking: UploadChunking = .adaptive
    ) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.target = .endpoint(endpoint)
        self.requestTimeout = requestTimeout
        self.installID = installID
        self.capabilities = capabilities
        self.chunking = chunking
    }

    /// Browse for the paired Mac (≤ `timeout`), connect with TLS-PSK, send hello.
    public func connect(timeout: TimeInterval = 8) async throws -> SyncSession {
        try await open(nil, timeout: timeout)
    }

    /// Connect to an endpoint the caller already holds — normally
    /// `MacPresenceMonitor.presence.endpoint` — instead of browsing for the
    /// Mac a second time (which costs most of a second, and a whole `timeout`
    /// when the Mac is away). Same TLS-PSK and hello as `connect(timeout:)`;
    /// the `welcome` must still come from the paired Mac.
    public func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> SyncSession {
        try await open(endpoint, timeout: timeout)
    }

    private func open(_ known: NWEndpoint?, timeout: TimeInterval) async throws -> SyncSession {
        let deadline = Date().addingTimeInterval(timeout)
        let endpoint: NWEndpoint
        switch (known, target) {
        case (let known?, _):
            endpoint = known
        case (nil, .endpoint(let explicit)):
            endpoint = explicit
        case (nil, .bonjour):
            endpoint = try await BonjourBrowsing.find(macID: pairing.macID, timeout: timeout)
        }
        let identity = pairing.deviceID
        let key = pairing.key
        let connection = try await BonjourBrowsing.openConnection(
            to: endpoint, deadline: deadline,
            parameters: { TLSPSK.clientParameters(identity: identity, key: key) })
        let hello = HelloMessage(
            protocolVersion: SyncConstants.protocolVersion,
            deviceID: pairing.deviceID,
            deviceName: deviceName,
            deviceModel: deviceModel,
            appVersion: appVersion,
            capabilities: capabilities,
            installID: installID)
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
                // The Mac answers with the version the connection speaks: the
                // lower of the two. Anything above ours is one we cannot speak.
                guard (SyncConstants.oldestProtocolVersion...SyncConstants.protocolVersion)
                    .contains(welcome.protocolVersion)
                else {
                    throw SyncError.protocolError(
                        code: ErrorCode.versionMismatch.rawValue,
                        message: "the Mac answered protocol v\(welcome.protocolVersion); this iPhone speaks up to v\(SyncConstants.protocolVersion)")
                }
                return SyncSession(
                    connection: connection, welcome: welcome, requestTimeout: requestTimeout,
                    credential: (identity, key), announced: Set(capabilities), chunking: chunking)
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

    /// Per-request timeout: sending the request and waiting for its reply
    /// each get this long (sync-protocol.md § Limits and timeouts).
    @_spi(Testing) public static let requestTimeout: TimeInterval = 30
    private let requestTimeout: TimeInterval
    /// The identity and key this session authenticated with.
    private let credential: (deviceID: String, key: Data)
    /// What this side announced in `hello`.
    private let announced: Set<String>
    private let chunking: UploadChunking

    init(
        connection: FramedConnection, welcome: Welcome, requestTimeout: TimeInterval = SyncSession.requestTimeout,
        credential: (deviceID: String, key: Data) = ("", Data()), announced: Set<String> = [],
        chunking: UploadChunking = .adaptive
    ) {
        self.connection = connection
        self.welcome = welcome
        self.requestTimeout = requestTimeout
        self.credential = credential
        self.announced = announced
        self.chunking = chunking
    }

    /// Whether both sides announced `capability` (`SyncCapability`): only
    /// then may this session use it.
    public func supports(_ capability: String) -> Bool {
        announced.contains(capability) && welcome.capabilities.contains(capability)
    }

    /// Asks the Mac for a credential to replace the one this session used
    /// (sync-protocol.md § Key rotation). Store it as `PairedMac.pending`,
    /// then connect with it: the Mac keeps accepting the old one until it has
    /// seen the new one used. Throws `protocolError("unsupported")` without
    /// touching the connection unless both sides announced
    /// `SyncCapability.rekey`, and `protocolError("unavailable")` when the
    /// Mac has no key to give right now (ask again on a later connection).
    public func rekey() async throws -> DeviceCredential {
        guard supports(SyncCapability.rekey) else { throw Self.unsupported(SyncCapability.rekey) }
        let exchange = RekeyExchange.Request()
        let reply = try await request(.rekey(exchange.message))
        guard case .rekeyed(let rekeyed) = reply else { throw Self.unexpected(reply, expected: "rekeyed") }
        return try RekeyExchange.open(
            rekeyed, for: exchange, oldDeviceID: credential.deviceID, oldKey: credential.key)
    }

    /// Tells the Mac to forget this iPhone ("Forget this Mac"). The Mac
    /// closes the connection after answering. Throws
    /// `protocolError("unsupported")` unless both sides announced
    /// `SyncCapability.unpair`.
    public func unpair() async throws {
        guard supports(SyncCapability.unpair) else { throw Self.unsupported(SyncCapability.unpair) }
        let reply = try await request(.unpair)
        guard case .unpaired = reply else { throw Self.unexpected(reply, expected: "unpaired") }
        connection.cancel()
    }

    private static func unsupported(_ capability: String) -> SyncError {
        .protocolError(code: "unsupported", message: "\(capability) is not announced by both sides")
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
        var sizer = UploadChunkSizer(chunking)
        progress(offset, total)
        while offset < total {
            // Forgetting the Mac or running out of background time cancels the
            // task; stop between chunks (the Mac keeps what it has, a later
            // offer resumes from there).
            try Task.checkCancellation()
            let length = Int(min(Int64(sizer.size), total - offset))
            let started = DispatchTime.now()
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
                sizer.record(
                    bytes: body.count,
                    seconds: Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9)
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

        try Task.checkCancellation()
        let commitReply = try await request(.commit(CommitMessage(recordingID: manifest.id)))
        guard case .committed(let committed) = commitReply else {
            throw Self.unexpected(commitReply, expected: "committed")
        }
        return committed.status.limited(to: statusExtras)
    }

    /// Asked in batches of `SyncConstants.statusBatchSize`: one reply for
    /// hundreds of IDs would not fit the frame header, and the Mac would hang
    /// up instead of answering.
    public func status(_ recordingIDs: [String]) async throws -> [RemoteStatus] {
        var items: [RemoteStatus] = []
        var start = 0
        repeat {
            let batch = Array(recordingIDs[start..<min(start + SyncConstants.statusBatchSize, recordingIDs.count)])
            let reply = try await request(.status(StatusRequestMessage(recordingIDs: batch)))
            guard case .statusReply(let status) = reply else {
                throw Self.unexpected(reply, expected: "statusReply")
            }
            // Extras of a feature the two sides did not both announce are
            // not used, whatever the Mac sent.
            items.append(contentsOf: status.items.map { $0.limited(to: statusExtras) })
            start += SyncConstants.statusBatchSize
        } while start < recordingIDs.count
        return items
    }

    /// The transcript of a finished recording; nil when the Mac has none
    /// (also when all it has is a partial one: see `fetchTranscript`).
    public func transcript(_ recordingID: String) async throws -> String? {
        guard let fetched = try await fetchTranscript(recordingID), !fetched.isPartial else { return nil }
        return fetched.text
    }

    /// What the Mac has to read for `recordingID`: the whole transcript, or —
    /// when both sides announced `SyncCapability.partialTranscript` — the
    /// parts it could transcribe of a recording it gave up on
    /// (`isPartial`). nil when it has neither.
    public func fetchTranscript(_ recordingID: String) async throws -> FetchedTranscript? {
        let reply = try await request(.transcript(TranscriptRequestMessage(recordingID: recordingID)))
        guard case .transcriptReply(let header, let body) = reply,
            header.recordingID == recordingID
        else { throw Self.unexpected(reply, expected: "transcriptReply") }
        guard header.available else { return nil }
        let partial = header.partial == true
        // A Mac marks a reply partial only for a phone that asked to be told;
        // one that does so anyway is not handed to the app as a transcript.
        if partial, !supports(SyncCapability.partialTranscript) { return nil }
        return FetchedTranscript(text: String(decoding: body, as: UTF8.self), isPartial: partial)
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
        // Cancelled before asking: nothing is in flight, the session is intact.
        if Task.isCancelled {
            await gate.release()
            throw CancellationError()
        }
        let connection = self.connection
        let reply: WireMessage
        do {
            let timeout = requestTimeout
            // Network.framework I/O does not observe Task cancellation: a
            // cancelled sync run would sit in `receive` until the timeout.
            // Closing the connection is what unblocks it — and the only safe
            // outcome anyway, since a reply still in flight would be read as
            // the answer to the next request.
            reply = try await withTaskCancellationHandler {
                try await connection.send(message, timeout: timeout)
                guard let received = try await connection.receive(timeout: timeout) else {
                    throw SyncError.connectionClosed
                }
                return received
            } onCancel: {
                connection.cancel()
            }
        } catch {
            // A request that failed in transit leaves the connection dead or
            // the stream at no known position: the session is over. Saying so
            // here also keeps `close()` from waiting on a goodbye nobody reads.
            connection.cancel()
            await gate.release()
            if Task.isCancelled { throw CancellationError() }
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

// MARK: - chunk size

/// How an upload sizes its chunks. `.adaptive` is what the app does; `.fixed`
/// is for tests that need to know where the chunk boundaries fall, and for
/// measuring against the old fixed size.
@_spi(Testing)
public enum UploadChunking: Sendable, Equatable {
    case adaptive
    case fixed(Int)
}

/// How much of a recording goes into the next `chunk`.
///
/// Uploads are stop-and-wait — one chunk, one acknowledgement — so every
/// chunk costs a round trip on top of its bytes. At a fixed 256 KiB a
/// two-hour recording is over 220 round trips, and on a link with 25 ms of
/// latency each way that alone is 11 s. So the size follows the link: while
/// chunks are acknowledged quickly it doubles, up to the frame limit (1 MiB,
/// which every version of the Mac accepts); when one takes long it halves, so
/// a slow link keeps its progress and its resume point fine-grained and stays
/// far from the request timeout.
struct UploadChunkSizer: Sendable, Equatable {
    /// A chunk acknowledged faster than this: the next one is twice as big.
    static let growBelow: TimeInterval = 1
    /// A chunk slower than this: the next one is half as big.
    static let shrinkAbove: TimeInterval = 5

    private(set) var size: Int
    private let adapts: Bool

    init(_ chunking: UploadChunking = .adaptive) {
        switch chunking {
        case .adaptive:
            size = SyncConstants.chunkSize
            adapts = true
        case .fixed(let bytes):
            size = min(max(bytes, 1), SyncConstants.maxBodyLength)
            adapts = false
        }
    }

    /// A chunk of `bytes` was acknowledged `seconds` after it was sent.
    mutating func record(bytes: Int, seconds: TimeInterval) {
        // The last chunk of a file, or one cut short: says nothing of the link.
        guard adapts, bytes >= size else { return }
        if seconds < Self.growBelow {
            size = min(size * 2, SyncConstants.maxBodyLength)
        } else if seconds > Self.shrinkAbove {
            size = max(size / 2, SyncConstants.minChunkSize)
        }
    }
}
