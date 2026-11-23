// Mac side: a TLS-PSK listener advertised on Bonjour (`_huske-sync._tcp`,
// TXT `v`/`mac`), one async request loop per connection, resumable uploads
// staged on disk, sha256-verified on commit, then handed to the delegate.
//
// Staging layout (all under `stagingDirectory`):
//   <id>.part            bytes received so far (resume offset = its size)
//   <id>.manifest.json   the manifest those bytes belong to
//   verified/<id>.<ext>  checksum-verified upload not (yet) taken by the
//                        delegate, plus verified/<id>.manifest.json

import Foundation
import Network

public protocol SyncServerDelegate: AnyObject, Sendable {
    /// A recording finished uploading and its checksum verified. `fileURL` lives
    /// in the server's staging directory. The delegate takes ownership (move it
    /// to the engine inbox) and returns the new status.
    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest,
        fileURL: URL, from device: PairedDevice) async -> RemoteStatus
    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus]
    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String?
    /// Pairing completed or a device's name changed (UI refresh).
    func syncServerDevicesChanged(_ server: SyncServer)
    /// Whether the Mac currently has a usable engine (reported in `welcome`).
    func syncServerEngineAvailable(_ server: SyncServer) -> Bool
    /// The phone offered a recording again that the Mac holds as `failed`:
    /// its user asked for another try (sync-protocol.md § Retrying). Re-queue
    /// it and return the new status, or nil to leave the failure as it is.
    /// Optional — the default does nothing.
    func syncServer(
        _ server: SyncServer, retryRequestedFor recordingID: String,
        from device: PairedDevice) async -> RemoteStatus?
    /// What could be transcribed of a recording the Mac gave up on, or nil
    /// when there is nothing of the kind. Asked only for a phone that
    /// announced `transcript.partial`, and only after `transcriptFor` said
    /// nil. Optional — the default has none.
    func syncServer(_ server: SyncServer, partialTranscriptFor recordingID: String) async -> String?
}

extension SyncServerDelegate {
    public func syncServer(
        _ server: SyncServer, retryRequestedFor recordingID: String,
        from device: PairedDevice
    ) async -> RemoteStatus? { nil }

    public func syncServer(
        _ server: SyncServer, partialTranscriptFor recordingID: String
    ) async -> String? { nil }
}

/// Live activity, for UI that wants more than the delegate's checkpoints
/// (e.g. a "receiving 42 %" row). Delivered on an arbitrary queue.
public enum SyncServerEvent: Sendable, Equatable {
    case listening(port: UInt16)
    case listenerFailed(String)
    case deviceConnected(PairedDevice)
    case devicePaired(PairedDevice)
    case deviceDisconnected(deviceID: String)
    case uploadStarted(RecordingManifest, offset: Int64, deviceID: String)
    case uploadProgress(recordingID: String, received: Int64, total: Int64)
    case uploadFailed(recordingID: String, reason: String)
    case uploadVerified(RecordingManifest, deviceID: String)
}

public final class SyncServer: @unchecked Sendable {
    public let registry: DeviceRegistry
    public let stagingDirectory: URL
    public let macName: String
    public let serverVersion: String
    private let requestedPort: UInt16

    private let lock = NSLock()
    private let stagingLock = NSLock()
    private let queue = DispatchQueue(label: "huske.sync.server")
    private weak var _delegate: SyncServerDelegate?
    private var _onEvent: (@Sendable (SyncServerEvent) -> Void)?
    private var _logHandler: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private var listenerGeneration = 0
    private var listenerFailures = 0
    private var restartInFlight = false
    private var boundPort: UInt16?
    private var running = false
    private var _lastError: String?
    private var _advertise = true
    // Reachability (SyncServerHealth.swift): whether phones can find this Mac.
    private var _health: SyncServerHealth = .stopped
    private var _onHealthChange: (@Sendable (SyncServerHealth) -> Void)?
    /// Advert endpoints the system confirmed for the current listener.
    private var advertEndpoints: Set<NWEndpoint> = []
    private var advertFailures = 0
    /// Pending "has the advert registered yet?" check.
    private var advertDeadline: DispatchWorkItem?
    private var listenerWaiting = false
    private var pathMonitor: NWPathMonitor?
    private var pathSeen = false
    private var pathSatisfied = true
    private var recheckScheduled = false
    private var probeInFlight = false
    private var _simulatesAdvert = false
    private var _advertGrace: TimeInterval = 10
    private var _recheckDebounce: TimeInterval = 1.5
    private var _retryDelay: (@Sendable (Int) -> TimeInterval)?
    private var _advertProbe: (@Sendable (String) async -> Bool?)?
    private var connections: [ObjectIdentifier: LiveConnection] = [:]
    private var pruneTimer: DispatchSourceTimer?
    private let identities = HandshakeIdentities()
    /// Pairing slots the current listener already carries a key for but
    /// nobody knows yet — see `makeInvite()`. Only valid for the listener of
    /// `reservedGeneration`.
    private var reservedSlots: [(deviceID: String, key: Data)] = []
    private var reservedGeneration = -1
    /// Every PSK identity the current listener carries a key for.
    private var listenerIdentities: Set<String> = []
    /// When a connection last opened or closed, or a spare slot was taken:
    /// what "a quiet moment" is measured from.
    private var lastActivity = Date.distantPast
    private var _replenishQuietPeriod = SyncServer.replenishQuietPeriod
    private var _capabilities = SyncConstants.capabilities
    /// Recordings being verified or handed to the delegate right now.
    private var handingOff: Set<String> = []
    private var _hashFile: @Sendable (URL) async throws -> (Int64, String) = FileHashing.sha256Detached

    private final class LiveConnection: @unchecked Sendable {
        let framed: FramedConnection
        var deviceID: String?
        init(_ framed: FramedConnection) { self.framed = framed }
    }

    /// Spare slots each listener starts with. A pairing takes two: one for
    /// the invite, one for the key that replaces the invite's (`rekey`). 64
    /// is 32 pairings without a single quiet moment in between, which is not
    /// something a person does; the keys cost nothing to carry.
    static let spareSlots = 64
    /// With fewer spares than this left, the listener is replaced (it then
    /// starts with a full set) at the next quiet moment, so the pool never
    /// runs dry while someone is pairing.
    static let spareLowWater = 16
    /// How long nothing may have happened for a moment to count as quiet.
    static let replenishQuietPeriod: TimeInterval = 60

    /// Idle time before a silent connection is closed (sync-protocol.md §
    /// Limits and timeouts).
    static let idleTimeout: TimeInterval = 120
    private var _idleTimeout = SyncServer.idleTimeout

    public init(
        registry: DeviceRegistry, stagingDirectory: URL, macName: String,
        serverVersion: String, port: UInt16 = 0
    ) {
        self.registry = registry
        self.stagingDirectory = stagingDirectory
        self.macName = macName
        self.serverVersion = serverVersion
        self.requestedPort = port
    }

    deinit {
        listener?.cancel()
        pruneTimer?.cancel()
        pathMonitor?.cancel()
        advertDeadline?.cancel()
    }

    public var delegate: SyncServerDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    public var onEvent: (@Sendable (SyncServerEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    public var logHandler: (@Sendable (String) -> Void)? {
        get { lock.withLock { _logHandler } }
        set { lock.withLock { _logHandler = newValue } }
    }

    /// Advertise on Bonjour (default true). Tests that connect to an explicit
    /// endpoint can turn it off before `start()`.
    @_spi(Testing)
    public var advertisesService: Bool {
        get { lock.withLock { _advertise } }
        set { lock.withLock { _advertise = newValue } }
    }

    /// Test hook: close silent connections sooner than `Self.idleTimeout`.
    /// Applies to the next wait of every connection.
    @_spi(Testing)
    public var idleTimeout: TimeInterval {
        get { lock.withLock { _idleTimeout } }
        set { lock.withLock { _idleTimeout = newValue } }
    }

    /// Test hook: how many times the listener has been replaced or stopped.
    /// Unchanged across a call = that call left the listener (and its
    /// Bonjour advert) alone.
    @_spi(Testing)
    public var listenerEpoch: Int { lock.withLock { listenerGeneration } }

    /// Test seam: spare slots the current listener still has.
    @_spi(Testing)
    public var spareSlotCount: Int {
        lock.withLock { reservedGeneration == listenerGeneration ? reservedSlots.count : 0 }
    }

    /// Test seam: replaces `Self.replenishQuietPeriod`.
    @_spi(Testing)
    public var replenishQuietPeriod: TimeInterval {
        get { lock.withLock { _replenishQuietPeriod } }
        set { lock.withLock { _replenishQuietPeriod = newValue } }
    }

    /// Test seam: the features this Mac announces in `welcome` and serves —
    /// set to stand in for a Huske.app that predates one of them.
    @_spi(Testing)
    public var capabilities: [String] {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }

    /// Test seam: the SHA-256 pass `commit` runs over a finished upload.
    var hashFile: @Sendable (URL) async throws -> (Int64, String) {
        get { lock.withLock { _hashFile } }
        set { lock.withLock { _hashFile = newValue } }
    }

    public var isRunning: Bool { lock.withLock { running } }

    /// The bound port once the listener is ready.
    public var port: UInt16? { lock.withLock { running ? boundPort : nil } }

    /// Why the listener is not listening, when it is not.
    public var lastError: String? { lock.withLock { _lastError } }

    /// Whether paired phones can find and reach this Mac right now. Unlike
    /// `port`, `.listening` also means the system confirmed the advert.
    public var health: SyncServerHealth { lock.withLock { _health } }

    /// Called whenever `health` changes, on an arbitrary queue. Calls can
    /// arrive out of order across queues: read `health` for the truth.
    public var onHealthChange: (@Sendable (SyncServerHealth) -> Void)? {
        get { lock.withLock { _onHealthChange } }
        set { lock.withLock { _onHealthChange = newValue } }
    }

    /// Paired devices with a connection open right now.
    public var connectedDeviceIDs: Set<String> {
        lock.withLock { Set(connections.values.compactMap(\.deviceID)) }
    }

    /// Test seam: expect an advert without registering one with the system,
    /// so registration changes come only from `simulateServiceRegistration`.
    @_spi(Testing)
    public var simulatesAdvertRegistration: Bool {
        get { lock.withLock { _simulatesAdvert } }
        set { lock.withLock { _simulatesAdvert = newValue } }
    }

    /// Test seam: how long a bound listener may go without a confirmed advert
    /// before the Mac counts as not advertising (default 10 s).
    @_spi(Testing)
    public var advertGrace: TimeInterval {
        get { lock.withLock { _advertGrace } }
        set { lock.withLock { _advertGrace = newValue } }
    }

    /// Test seam: how long `recheck` waits to coalesce a burst (default 1.5 s).
    @_spi(Testing)
    public var recheckDebounce: TimeInterval {
        get { lock.withLock { _recheckDebounce } }
        set { lock.withLock { _recheckDebounce = newValue } }
    }

    /// Test seam: replaces `listenerRetryDelay(afterFailures:)`.
    @_spi(Testing)
    public var retryDelayOverride: (@Sendable (Int) -> TimeInterval)? {
        get { lock.withLock { _retryDelay } }
        set { lock.withLock { _retryDelay = newValue } }
    }

    /// Test seam: replaces the Bonjour self-check `recheck` runs. true = this
    /// Mac's advert is visible, false = it is not, nil = could not tell.
    @_spi(Testing)
    public var advertProbe: (@Sendable (_ macID: String) async -> Bool?)? {
        get { lock.withLock { _advertProbe } }
        set { lock.withLock { _advertProbe = newValue } }
    }

    // MARK: lifecycle

    public func start() throws {
        try FileManager.default.createDirectory(
            at: stagingDirectory.appendingPathComponent("verified", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let alreadyRunning: Bool = lock.withLock {
            if running { return true }
            running = true
            _lastError = nil
            listenerGeneration += 1
            return false
        }
        guard !alreadyRunning else { return }
        registry.pruneExpired()
        log("sync server starting (macID \(registry.macID))")
        setHealth(.starting)
        let generation = lock.withLock { listenerGeneration }
        do {
            try startListener(port: requestedPort, generation: generation, fallbackToEphemeral: false)
        } catch {
            lock.withLock { running = false }
            setHealth(.stopped)
            throw error
        }
        startPruneTimer()
        startPathMonitor()
    }

    public func stop() {
        let (old, live, timer): (NWListener?, [LiveConnection], DispatchSourceTimer?) = lock.withLock {
            running = false
            listenerGeneration += 1
            let old = listener
            listener = nil
            boundPort = nil
            restartInFlight = false
            let live = Array(connections.values)
            connections.removeAll()
            let timer = pruneTimer
            pruneTimer = nil
            return (old, live, timer)
        }
        let monitor: NWPathMonitor? = lock.withLock {
            clearAdvertLocked()
            listenerFailures = 0
            advertFailures = 0
            recheckScheduled = false
            let monitor = pathMonitor
            pathMonitor = nil
            return monitor
        }
        old?.cancel()
        timer?.cancel()
        monitor?.cancel()
        for connection in live { connection.framed.cancel() }
        registry.flushContacts()
        setHealth(.stopped)
        log("sync server stopped")
    }

    /// Waits until the listener is bound (or `timeout`). Returns the port.
    public func waitUntilReady(timeout: TimeInterval = 5) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (ready, port): (Bool, UInt16?) = lock.withLock {
                (running && listener != nil && !restartInFlight && boundPort != nil, boundPort)
            }
            if ready { return port }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: pairing

    /// Mint + register a pending invite.
    ///
    /// A running listener cannot be given a new key, and replacing it takes
    /// the Bonjour advert down for about a second — every phone watching sees
    /// the Mac vanish. So each listener starts with a few spare slots whose
    /// keys it already carries, and an invite normally just takes one: the
    /// handshake's selection block refuses a slot until the registry knows
    /// it. Only when the spares run out is the listener replaced.
    public func makeInvite() -> PairingInvite {
        registry.pruneExpired()
        if let reserved = takeSpare() {
            let invite = PairingInvite(
                macID: registry.macID, macName: macName, deviceID: reserved.deviceID,
                key: reserved.key, expiresAt: Date().addingTimeInterval(SyncConstants.inviteLifetime))
            registry.addPending(invite)
            log("pairing invite minted for device \(invite.deviceID.prefix(8))…")
            return invite
        }
        let invite = PairingInvite.mint(macID: registry.macID, macName: macName)
        registry.addPending(invite)
        log("pairing invite minted for device \(invite.deviceID.prefix(8))… (no spare slot: replacing the listener)")
        restartListener()
        return invite
    }

    /// A spare slot of the current listener, or nil when it has none left
    /// (or is being replaced).
    private func takeSpare() -> (deviceID: String, key: Data)? {
        lock.withLock {
            guard running, listener != nil, reservedGeneration == listenerGeneration,
                !reservedSlots.isEmpty
            else { return nil }
            lastActivity = Date()
            return reservedSlots.removeFirst()
        }
    }

    /// Replaces the listener — the new one starts with a full set of spare
    /// slots — if the spares are running low *and* nobody would notice the
    /// second its Bonjour advert is away: no connection is open, nothing has
    /// happened for `replenishQuietPeriod`, and no pairing code is waiting to
    /// be scanned. Runs with the prune timer. Returns whether it did.
    @_spi(Testing)
    @discardableResult
    public func replenishSparesIfQuiet(now: Date = .now) -> Bool {
        let low: Bool = lock.withLock {
            running && listener != nil && !restartInFlight && boundPort != nil
                && reservedGeneration == listenerGeneration
                && reservedSlots.count < Self.spareLowWater
                && connections.isEmpty
                && now.timeIntervalSince(lastActivity) >= _replenishQuietPeriod
        }
        // Someone may be about to scan a code: the Mac must not vanish now.
        guard low, !registry.hasLiveInvite(now: now) else { return false }
        log("spare pairing slots are running low; replacing the listener while nothing is connected")
        restartListener()
        return true
    }

    /// Forget a device. Its connections are closed; the listener stays — the
    /// handshake's selection block refuses any identity the registry no
    /// longer holds, so the key it still carries is dead weight until the
    /// next listener.
    public func removeDevice(_ deviceID: String) {
        registry.remove(deviceID: deviceID)
        closeConnections(ofDevice: deviceID)
        log("device \(deviceID.prefix(8))… removed")
        delegate?.syncServerDevicesChanged(self)
    }

    /// Closes every connection that authenticated as `deviceID`, except
    /// `keeping` (the one that is still owed an answer).
    private func closeConnections(ofDevice deviceID: String, keeping: LiveConnection? = nil) {
        let doomed: [LiveConnection] = lock.withLock {
            connections.values.filter { $0.deviceID == deviceID && $0 !== keeping }
        }
        for connection in doomed { connection.framed.cancel() }
    }

    // MARK: listener

    private func startListener(port: UInt16, generation: Int, fallbackToEphemeral: Bool) throws {
        var keys = registry.activeKeys()
        // Spare pairing slots for `makeInvite()`: random identities + keys
        // nobody has been shown. Unusable until an invite puts one in the
        // registry, because `select` below only accepts registered devices.
        let spares = (0..<Self.spareSlots).map { _ in DeviceCredential.mint() }
        for spare in spares { keys[spare.deviceID] = spare.key }
        let carried = Set(keys.keys)
        let registry = self.registry
        let identities = self.identities
        let params = TLSPSK.serverParameters(keys: keys, queue: queue) { metadata, identity in
            // A device's own identity, or the one `rekey` issued and it has
            // not used yet: both work until the new one is used.
            guard let device = registry.device(forIdentity: identity), !device.isExpired() else {
                return false
            }
            identities.record(metadata, identity: identity)
            return true
        }
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: params)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw SyncError.io("invalid port \(port)")
            }
            listener = try NWListener(using: params, on: nwPort)
        }
        let (advertise, simulated): (Bool, Bool) = lock.withLock { (_advertise, _simulatesAdvert) }
        if advertise {
            if !simulated {
                var txt = NWTXTRecord()
                txt["v"] = String(SyncConstants.protocolVersion)
                txt["mac"] = registry.macID
                listener.service = NWListener.Service(
                    name: macName, type: SyncConstants.serviceType, domain: nil, txtRecord: txt)
            }
            // A bound port is not an advert: only this says the system took it.
            listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
                guard let self, let listener else { return }
                self.advertChanged(listener, change: change, generation: generation)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.listenerStateChanged(
                listener, state: state, generation: generation, port: port,
                fallbackToEphemeral: fallbackToEphemeral)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        let current: Bool = lock.withLock {
            guard running, generation == listenerGeneration else { return false }
            self.listener = listener
            reservedSlots = spares.map { ($0.deviceID, $0.key) }
            reservedGeneration = generation
            listenerIdentities = carried
            clearAdvertLocked()
            return true
        }
        guard current else { return }
        listener.start(queue: queue)
        logRoutine("listener starting with \(keys.count - spares.count) device key(s)\(port == 0 ? "" : " on port \(port)")")
    }

    private func listenerStateChanged(
        _ listener: NWListener, state: NWListener.State, generation: Int, port: UInt16,
        fallbackToEphemeral: Bool
    ) {
        let isCurrent: Bool = lock.withLock { generation == listenerGeneration && self.listener === listener }
        switch state {
        case .ready:
            guard isCurrent else { return }
            let bound = listener.port?.rawValue
            // Reachable only once the advert is confirmed too (`advertChanged`).
            let advertPending: Bool = lock.withLock {
                boundPort = bound
                restartInFlight = false
                listenerFailures = 0
                listenerWaiting = false
                _lastError = nil
                return _advertise && advertEndpoints.isEmpty
            }
            if let bound {
                logRoutine("listening on port \(bound)")
                emit(.listening(port: bound))
                if advertPending {
                    awaitAdvert(generation: generation)
                } else {
                    setHealth(.listening(port: bound))
                }
            }
        case .failed(let error):
            listener.cancel()
            guard isCurrent else { return }
            if fallbackToEphemeral, port != 0 {
                // The previous port could not be re-bound; any port will do —
                // phones resolve the Mac through Bonjour every time.
                log("could not re-bind port \(port) (\(error)); using an ephemeral port")
                do {
                    try startListener(port: 0, generation: generation, fallbackToEphemeral: false)
                } catch let startError {
                    listenerWentDown(
                        "listener failed: \(startError)", reason: .other("\(startError)"), generation: generation)
                }
                return
            }
            listenerWentDown("listener failed: \(error)", reason: .init(error), generation: generation)
        case .waiting(let error):
            // Not listening (e.g. Local Network access denied, no network);
            // Network.framework moves it back to `.ready` on its own.
            guard isCurrent else { return }
            let message = DiscoveryIssue(error) == .localNetworkDenied
                ? "listener waiting: Local Network access is off for this app"
                : "listener waiting: \(error)"
            lock.withLock {
                _lastError = message
                listenerWaiting = true
            }
            log(message)
            emit(.listenerFailed(message))
            setHealth(.notAdvertising(.init(error)))
        default:
            break
        }
    }

    /// No listener: say so, and come back on our own with backoff. `running`
    /// is still true, so the app's start() is a no-op: unless the server
    /// restarts itself, the Mac stays unreachable until relaunch.
    private func listenerWentDown(_ message: String, reason: SyncServerHealth.Reason, generation: Int) {
        let plan: (delay: TimeInterval, failures: Int)? = lock.withLock {
            guard running, generation == listenerGeneration else { return nil }
            _lastError = message
            listener = nil
            boundPort = nil
            restartInFlight = false
            clearAdvertLocked()
            listenerFailures += 1
            return (retryDelayLocked(afterFailures: listenerFailures), listenerFailures)
        }
        guard let plan else { return }
        // A failure that keeps repeating says nothing new every 30 s.
        if Self.isWorthLogging(repeat: plan.failures) {
            log("\(message); retrying in \(Int(plan.delay)) s")
        }
        emit(.listenerFailed(message))
        setHealth(.recovering(reason))
        queue.asyncAfter(deadline: .now() + plan.delay) { [weak self] in
            guard let self else { return }
            let stillDown = self.lock.withLock {
                self.running && self.listener == nil && self.listenerGeneration == generation
            }
            if stillDown { self.restartListener() }
        }
    }

    // MARK: advert

    /// The system registered or withdrew this Mac's Bonjour advert.
    private func advertChanged(
        _ listener: NWListener, change: NWListener.ServiceRegistrationChange, generation: Int
    ) {
        enum Outcome { case ignored, confirmed(UInt16), withdrawn }
        let outcome: Outcome = lock.withLock {
            guard generation == listenerGeneration, self.listener === listener else { return .ignored }
            switch change {
            case .add(let endpoint):
                advertEndpoints.insert(endpoint)
                advertFailures = 0
                advertDeadline?.cancel()
                advertDeadline = nil
                // Before `.ready` the port is not known yet; `.ready` reports it.
                guard let port = boundPort, !restartInFlight, !listenerWaiting else { return .ignored }
                return .confirmed(port)
            case .remove(let endpoint):
                advertEndpoints.remove(endpoint)
                guard advertEndpoints.isEmpty, boundPort != nil, !restartInFlight else { return .ignored }
                return .withdrawn
            @unknown default:
                return .ignored
            }
        }
        switch outcome {
        case .ignored:
            break
        case .confirmed(let port):
            logRoutine("advert registered; phones can find this Mac")
            setHealth(.listening(port: port))
        case .withdrawn:
            log("the system withdrew this Mac's advert")
            awaitAdvert(generation: generation)
        }
    }

    /// The port is bound but the system has not said the advert is up. Give
    /// it `advertGrace`; after that the Mac is invisible, whatever the port says.
    private func awaitAdvert(generation: Int) {
        let item = DispatchWorkItem { [weak self] in self?.advertOverdue(generation: generation) }
        let grace: TimeInterval = lock.withLock {
            advertDeadline?.cancel()
            advertDeadline = item
            return _advertGrace
        }
        queue.asyncAfter(deadline: .now() + grace, execute: item)
    }

    private func advertOverdue(generation: Int) {
        let plan: (delay: TimeInterval, failures: Int)? = lock.withLock {
            guard running, generation == listenerGeneration, listener != nil, boundPort != nil,
                !restartInFlight, advertEndpoints.isEmpty
            else { return nil }
            advertDeadline = nil
            advertFailures += 1
            return (retryDelayLocked(afterFailures: advertFailures), advertFailures)
        }
        guard let plan else { return }
        if Self.isWorthLogging(repeat: plan.failures) {
            log("the system has not confirmed this Mac's advert, so phones cannot find it; "
                + "announcing again in \(Int(plan.delay)) s")
        }
        setHealth(.notAdvertising(.advertNotRegistered))
        queue.asyncAfter(deadline: .now() + plan.delay) { [weak self] in
            guard let self else { return }
            let stillMissing = self.lock.withLock {
                self.running && self.listenerGeneration == generation && self.advertEndpoints.isEmpty
            }
            if stillMissing { self.restartListener() }
        }
    }

    /// Forget what the previous listener's advert looked like. Lock held.
    private func clearAdvertLocked() {
        advertEndpoints.removeAll()
        advertDeadline?.cancel()
        advertDeadline = nil
        listenerWaiting = false
    }

    // MARK: recheck

    /// Something outside changed: the Mac woke, the network changed, the user
    /// is looking at the pane. Make sure phones can still find this Mac, and
    /// repair it now rather than at the next backoff step. Cheap when all is
    /// well; bursts (a wake brings several network changes) are coalesced.
    public func recheck(reason: String) {
        let debounce: TimeInterval? = lock.withLock {
            guard running, !recheckScheduled else { return nil }
            recheckScheduled = true
            return _recheckDebounce
        }
        guard let debounce else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.performRecheck(reason: reason)
        }
    }

    private func performRecheck(reason: String) {
        enum Action { case none, rebuild(String), probe(generation: Int) }
        let action: Action = lock.withLock {
            recheckScheduled = false
            guard running, !restartInFlight else { return .none }
            guard listener != nil else {
                // Down and sitting out a backoff step: circumstances changed.
                listenerFailures = 0
                return .rebuild("starting the listener again now")
            }
            if listenerWaiting { return .rebuild("the listener was waiting; rebuilding it") }
            guard boundPort != nil, _advertise else { return .none }
            if advertEndpoints.isEmpty {
                // Inside the grace period `advertOverdue` has it in hand.
                guard advertDeadline == nil else { return .none }
                advertFailures = 0
                return .rebuild("announcing this Mac again now")
            }
            guard !probeInFlight else { return .none }
            probeInFlight = true
            return .probe(generation: listenerGeneration)
        }
        switch action {
        case .none:
            break
        case .rebuild(let what):
            log("\(reason): \(what)")
            restartListener()
        case .probe(let generation):
            verifyAdvert(reason: reason, generation: generation)
        }
    }

    /// The state says "registered"; look for the advert the way a phone does.
    /// After a sleep or a network change the two can disagree, and then the
    /// Mac says it is reachable while nothing can find it.
    private func verifyAdvert(reason: String, generation: Int) {
        let macID = registry.macID
        let (custom, online) = lock.withLock { (_advertProbe, pathSatisfied) }
        Task { [weak self] in
            let visible: Bool?
            if let custom {
                visible = await custom(macID)
            } else if online {
                visible = await Self.advertIsVisible(macID: macID, timeout: 4)
            } else {
                // Without a network, not finding it says nothing about the advert.
                visible = nil
            }
            guard let self else { return }
            let rebuild: Bool = self.lock.withLock {
                self.probeInFlight = false
                return visible == false && self.running && self.listenerGeneration == generation
                    && self.listener != nil && !self.restartInFlight
            }
            guard rebuild else {
                if visible == true { self.log("\(reason): phones can still find this Mac") }
                return
            }
            self.log("\(reason): this Mac's advert is not visible; announcing it again")
            self.setHealth(.notAdvertising(.advertNotRegistered))
            self.restartListener()
        }
    }

    /// Network changes re-run the check (the first update is just the current
    /// state). The monitor cannot be restarted, so each `start()` makes one.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let changed: Bool = self.lock.withLock {
                let first = !self.pathSeen
                self.pathSeen = true
                self.pathSatisfied = path.status == .satisfied
                return !first
            }
            if changed { self.recheck(reason: "the network changed") }
        }
        let previous: NWPathMonitor? = lock.withLock {
            let previous = pathMonitor
            pathMonitor = monitor
            pathSeen = false
            pathSatisfied = true
            return previous
        }
        previous?.cancel()
        monitor.start(queue: queue)
    }

    // MARK: health

    private func setHealth(_ health: SyncServerHealth) {
        let handler: (@Sendable (SyncServerHealth) -> Void)? = lock.withLock {
            guard _health != health else { return nil }
            _health = health
            return _onHealthChange
        }
        handler?(health)
    }

    /// Lock held.
    private func retryDelayLocked(afterFailures count: Int) -> TimeInterval {
        _retryDelay?(count) ?? Self.listenerRetryDelay(afterFailures: count)
    }

    /// The first few rounds of a repeating failure, then every tenth: at the
    /// 30 s cap that is one line every five minutes instead of 2 900 a day.
    static func isWorthLogging(repeat count: Int) -> Bool {
        count <= 3 || count % 10 == 0
    }

    /// Lines every listener (re)start prints. While a failure keeps repeating
    /// they would bury what led up to it, so they follow the same rule.
    private func logRoutine(_ message: String) {
        let rounds = lock.withLock { max(listenerFailures, advertFailures) }
        if Self.isWorthLogging(repeat: rounds) { log(message) }
    }

    /// Backoff between listener restarts after a failure: 1, 2, 4, 8, 16, 30, 30… s.
    static func listenerRetryDelay(afterFailures count: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, count - 1))))
    }

    /// Test seam: deliver `state` to the current listener's handler on the
    /// server queue, as Network.framework would (e.g. a runtime `.failed`).
    @_spi(Testing)
    public func simulateListenerState(_ state: NWListener.State) {
        guard let handler = lock.withLock({ listener?.stateUpdateHandler }) else { return }
        queue.sync { handler(state) }
    }

    /// Test seam: deliver an advert registration change to the current
    /// listener's handler on the server queue, as the system would.
    @_spi(Testing)
    public func simulateServiceRegistration(_ change: NWListener.ServiceRegistrationChange) {
        guard let handler = lock.withLock({ listener?.serviceRegistrationUpdateHandler }) else { return }
        queue.sync { handler(change) }
    }

    /// Rebuild the listener so it carries the current key set. The new one
    /// re-binds the old port once the old listener has fully cancelled.
    private func restartListener() {
        let plan: (NWListener?, Int, UInt16?)? = lock.withLock {
            guard running else { return nil }
            listenerGeneration += 1
            let old = listener
            listener = nil
            restartInFlight = true
            clearAdvertLocked()
            return (old, listenerGeneration, boundPort ?? (requestedPort == 0 ? nil : requestedPort))
        }
        guard let plan else { return }
        let (old, generation, port) = plan
        let rebuild: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try self.startListener(
                    port: port ?? self.requestedPort, generation: generation,
                    fallbackToEphemeral: self.requestedPort == 0)
            } catch {
                // Used to stop here for good: no listener, and nothing to retry.
                self.listenerWentDown(
                    "listener restart failed: \(error)", reason: .other("\(error)"), generation: generation)
            }
        }
        guard let old else {
            queue.async(execute: rebuild)
            return
        }
        old.newConnectionHandler = { $0.cancel() }
        old.stateUpdateHandler = { state in
            if case .cancelled = state { rebuild() }
        }
        old.cancel()
    }

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pruneStalePartials()
            let removed = self.registry.pruneExpired()
            self.replenishSparesIfQuiet()
            guard !removed.isEmpty else { return }
            // No listener restart: an expired slot is already refused at
            // the handshake (the selection block asks the registry).
            self.log("expired \(removed.count) unused pairing invite(s)")
            self.delegate?.syncServerDevicesChanged(self)
        }
        lock.withLock { pruneTimer = timer }
        timer.resume()
    }

    /// Partial uploads nobody resumed for a week (the phone deleted the
    /// recording, or was unpaired) are dropped so staging can't grow forever.
    static let partialUploadLifetime: TimeInterval = 7 * 24 * 3600

    func pruneStalePartials(now: Date = .now) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: stagingDirectory.path) else { return }
        stagingLock.withLock {
            for name in names where name.hasSuffix(".part") {
                let part = stagingDirectory.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: part.path)[.modificationDate]) as? Date
                guard let modified, now.timeIntervalSince(modified) > Self.partialUploadLifetime else { continue }
                let id = String(name.dropLast(".part".count))
                // A commit is reading it right now (hashing runs unlocked).
                guard !isHandingOff(id) else { continue }
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: partManifestURL(id))
                log("dropped a partial upload untouched for a week (\(id.prefix(8))…)")
            }
        }
    }

    /// Verified uploads whose hand-off never completed (the app quit between
    /// commit and hand-off, or the delegate's move failed): give each to the
    /// delegate again. Call after `start()` once a delegate is attached.
    public func redeliverVerified() async {
        guard let delegate else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: verifiedDirectory.path) else { return }
        for name in names where name.hasSuffix(".manifest.json") {
            let id = String(name.dropLast(".manifest.json".count))
            // A commit (or another re-delivery) is handing this one over right
            // now. Giving it to the delegate twice at once is not harmless: the
            // receiver replaces its destination, so the second call can delete
            // the audio the first one just moved.
            guard beginHandOff(id) else {
                log("verified upload \(id.prefix(8))… is already being handed off — left alone")
                continue
            }
            // Read only once the claim is ours: whoever held it may just have
            // finished and taken the file.
            guard let manifest = verifiedManifest(id) else {
                endHandOff(id)
                continue
            }
            let fileURL = verifiedFileURL(manifest)
            // Which phone sent it isn't kept past commit; its name is in the manifest.
            let device = PairedDevice(deviceID: "redelivery", key: Data(), name: manifest.deviceName)
            log("re-delivering verified upload \(id.prefix(8))…")
            _ = await delegate.syncServer(self, didReceive: manifest, fileURL: fileURL, from: device)
            if !fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: verifiedManifestURL(id))
            }
            endHandOff(id)
        }
    }

    /// Claims `id` for verification + hand-off; false when someone holds it.
    private func beginHandOff(_ id: String) -> Bool {
        lock.withLock { handingOff.insert(id).inserted }
    }

    private func endHandOff(_ id: String) {
        lock.withLock { _ = handingOff.remove(id) }
    }

    private func isHandingOff(_ id: String) -> Bool {
        lock.withLock { handingOff.contains(id) }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        let framed = FramedConnection(connection, label: "server-conn")
        let live = LiveConnection(framed)
        let accepted: Bool = lock.withLock {
            guard running else { return false }
            connections[ObjectIdentifier(live)] = live
            lastActivity = Date()
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        Task {
            await self.serve(live)
            self.lock.withLock {
                _ = self.connections.removeValue(forKey: ObjectIdentifier(live))
                self.lastActivity = Date()
            }
        }
    }

    private struct ConnectionContext {
        var device: PairedDevice?
        var tlsIdentity: String?
        /// What `hello` settled: the version this connection speaks and the
        /// additive features the phone announced. Handlers branch on these.
        var protocolVersion = SyncConstants.protocolVersion
        var capabilities: Set<String> = []
        var offered: [String: RecordingManifest] = [:]
        var close = false
    }

    private func serve(_ live: LiveConnection) async {
        let framed = live.framed
        defer { framed.cancel() }
        do {
            try await framed.start(timeout: 20)
        } catch {
            log("handshake with \(framed.endpointDescription) failed: \(error)")
            return
        }
        var context = ConnectionContext()
        if let metadata = TLSPSK.securityMetadata(of: framed.connection) {
            context.tlsIdentity = identities.take(metadata)
        }
        while !context.close {
            let message: WireMessage?
            do {
                message = try await framed.receive(timeout: idleTimeout)
            } catch let error as SyncError {
                if case .protocolError(let code, let text) = error {
                    // Malformed frame: say why, then hang up — the stream is
                    // no longer in a known position.
                    try? await framed.send(
                        .error(ErrorMessage(code: ErrorCode(rawValue: code) ?? .badRequest, message: text)),
                        timeout: 5)
                }
                break
            } catch {
                break
            }
            guard let message else { break }
            if case .bye = message { break }
            let reply = await handle(message, context: &context, live: live)
            // Every request is proof of life, not just `hello`.
            if let deviceID = context.device?.deviceID { registry.noteContact(deviceID: deviceID) }
            do {
                try await framed.send(reply)
            } catch SyncError.protocolError(let code, let text) where code == ErrorCode.tooLarge.rawValue {
                // The reply did not fit the frame limits, so nothing was sent:
                // say so instead of hanging up on a well-behaved request.
                log("\(reply.type) reply too large (\(text)); answered too_large")
                do {
                    try await framed.send(
                        .error(ErrorMessage(code: .tooLarge, message: "\(reply.type) reply too large; ask for fewer ids")))
                } catch {
                    break
                }
            } catch {
                break
            }
        }
        if let deviceID = context.device?.deviceID {
            registry.flushContacts()
            // Before the event, so `connectedDeviceIDs` already agrees with it.
            lock.withLock { live.deviceID = nil }
            emit(.deviceDisconnected(deviceID: deviceID))
            log("device \(context.device?.name ?? deviceID) disconnected")
        }
    }

    private func handle(
        _ message: WireMessage, context: inout ConnectionContext, live: LiveConnection
    ) async -> WireMessage {
        guard let device = context.device else {
            guard case .hello(let hello) = message else {
                context.close = true
                return .error(ErrorMessage(code: .notHello, message: "hello must be the first message"))
            }
            return handleHello(hello, context: &context, live: live)
        }
        do {
            switch message {
            case .hello:
                return .error(ErrorMessage(code: .badRequest, message: "hello already received"))
            case .offer(let offer):
                return try await handleOffer(offer.recording, context: &context, device: device)
            case .chunk(let chunk, let body):
                return try handleChunk(chunk, body: body, context: context)
            case .commit(let commit):
                return try await handleCommit(commit.recordingID, context: &context, device: device)
            case .status(let request):
                return try await handleStatus(request.recordingIDs, context: context)
            case .transcript(let request):
                return try await handleTranscript(request.recordingID, context: context)
            case .rekey(let request):
                return try handleRekey(request, context: context, device: device)
            case .unpair:
                return try handleUnpair(context: &context, device: device, live: live)
            default:
                return .error(ErrorMessage(code: .badRequest, message: "\(message.type) is not a request"))
            }
        } catch let reply as ReplyError {
            return .error(reply.message)
        } catch {
            log("internal error handling \(message.type): \(error)")
            return .error(ErrorMessage(code: .internal, message: "\(error)"))
        }
    }

    private struct ReplyError: Error {
        let message: ErrorMessage
        init(_ code: ErrorCode, _ text: String, received: Int64? = nil) {
            message = ErrorMessage(code: code, message: text, received: received)
        }
    }

    // MARK: hello

    private func handleHello(
        _ hello: HelloMessage, context: inout ConnectionContext, live: LiveConnection
    ) -> WireMessage {
        // Tolerant by design (sync-protocol.md § Versioning): the phone names
        // the highest version it speaks and the connection uses the lower of
        // the two, so a newer iPhone app keeps working with an older Huske.app.
        guard let version = SyncConstants.negotiatedVersion(withPeer: hello.protocolVersion) else {
            context.close = true
            return .error(
                ErrorMessage(
                    code: .versionMismatch,
                    message: "this Mac speaks protocol v\(SyncConstants.oldestProtocolVersion) to v\(SyncConstants.protocolVersion), the phone v\(hello.protocolVersion)"))
        }
        // Fail closed: a hello we cannot tie to the PSK the handshake used is
        // refused, so one paired key can never speak for another device.
        guard let tlsIdentity = context.tlsIdentity, tlsIdentity == hello.deviceID else {
            context.close = true
            log("hello deviceID does not match the TLS identity — refusing")
            return .error(ErrorMessage(code: .badRequest, message: "deviceID does not match the TLS identity"))
        }
        // The phone came back with the credential `rekey` gave it. That is
        // the proof the Mac waited for: from this write on it is the device's
        // only credential, and the one it replaces — the pairing link's — is
        // refused at the handshake (sync-protocol.md § Key rotation).
        let retired = registry.promoteSuccessor(identity: hello.deviceID)?.retired
        guard let existing = registry.device(id: hello.deviceID), !existing.isExpired() else {
            context.close = true
            return .error(ErrorMessage(code: .badRequest, message: "unknown device"))
        }
        let name = Self.clean(hello.deviceName)
        let model = Self.clean(hello.deviceModel)
        var changed: Bool
        if existing.isPaired {
            changed = registry.touch(
                deviceID: existing.deviceID, name: name, model: model, installID: hello.installID)
        } else {
            guard
                registry.markPaired(
                    deviceID: existing.deviceID, name: name, model: model, installID: hello.installID)
            else {
                context.close = true
                return .error(ErrorMessage(code: .badRequest, message: "pairing invite expired"))
            }
            changed = true
        }
        let device = registry.device(id: existing.deviceID) ?? existing
        context.device = device
        context.protocolVersion = version
        context.capabilities = Set(hello.capabilities)
        lock.withLock { live.deviceID = device.deviceID }
        if let retired {
            closeConnections(ofDevice: retired)
            log("\(device.name ?? "device") now uses the key this Mac issued; the pairing link's key no longer works")
            changed = true
        }
        if let installID = hello.installID {
            // A phone holds one pairing, and sends its install ID only with
            // the one it keeps: its other entries here are leftovers of
            // earlier pairings, with keys that still worked.
            let replaced = registry.removeOtherPairings(ofInstall: installID, keeping: device.deviceID)
            for deviceID in replaced { closeConnections(ofDevice: deviceID) }
            if !replaced.isEmpty {
                log("\(device.name ?? "device") paired again: removed \(replaced.count) earlier pairing(s) of the same iPhone")
                changed = true
            }
        }
        if !existing.isPaired {
            log("paired with \(device.name ?? device.deviceID)")
            emit(.devicePaired(device))
        }
        emit(.deviceConnected(device))
        log(
            "hello from \(device.name ?? device.deviceID) (\(device.model ?? "?"), app \(hello.appVersion), "
                + "protocol v\(version)\(hello.protocolVersion == version ? "" : " of its v\(hello.protocolVersion)")"
                + "\(hello.capabilities.isEmpty ? "" : ", capabilities \(hello.capabilities.sorted().joined(separator: " "))"))")
        let delegate = self.delegate
        if changed { delegate?.syncServerDevicesChanged(self) }
        return .welcome(
            Welcome(
                protocolVersion: version,
                macID: registry.macID,
                macName: macName,
                serverVersion: serverVersion,
                engineAvailable: delegate?.syncServerEngineAvailable(self) ?? false,
                capabilities: capabilities))
    }

    // MARK: key rotation + unpair

    /// `rekey`: hand the phone a credential to replace the one it paired
    /// with. A running listener cannot be given a key, and one identity
    /// cannot have two — so the new credential is one of the listener's spare
    /// slots, identity included. The old one keeps working until the phone
    /// says `hello` with the new one.
    private func handleRekey(
        _ request: RekeyMessage, context: ConnectionContext, device: PairedDevice
    ) throws -> WireMessage {
        guard capabilities.contains(SyncCapability.rekey), context.capabilities.contains(SyncCapability.rekey)
        else { throw ReplyError(.badRequest, "rekey was not announced by both sides") }
        // The registry is the truth: the device may have been removed, or
        // have rotated on another connection, since this one said hello.
        guard let current = registry.device(id: device.deviceID), current.isPaired else {
            throw ReplyError(.badRequest, "unknown device")
        }
        let carried: Bool = lock.withLock {
            current.successor.map { listenerIdentities.contains($0.deviceID) } ?? false
        }
        let credential: DeviceCredential
        let reply: RekeyedMessage
        do {
            if let pending = current.successor, carried {
                // Asked before, and the answer never arrived (or the phone
                // quit before storing it): the same credential again, so
                // retries do not eat the spare slots.
                credential = pending
                reply = try RekeyExchange.seal(
                    credential, for: request, oldDeviceID: current.deviceID, oldKey: current.key)
            } else {
                // Checked before a slot is spent on it.
                try RekeyExchange.check(request)
                guard let spare = takeSpare() else {
                    throw ReplyError(.unavailable, "no spare key slot right now; ask again on a later connection")
                }
                credential = DeviceCredential(deviceID: spare.deviceID, key: spare.key)
                reply = try RekeyExchange.seal(
                    credential, for: request, oldDeviceID: current.deviceID, oldKey: current.key)
                // Durable before it is sent: once the phone has it, the Mac
                // must accept it, across a relaunch too.
                guard registry.setSuccessor(credential, forDevice: current.deviceID) else {
                    throw ReplyError(.badRequest, "unknown device")
                }
            }
        } catch SyncError.protocolError(_, let message) {
            throw ReplyError(.badRequest, message)
        }
        log("issued a new key to \(current.name ?? "device") (\(credential.deviceID.prefix(8))…); "
            + "the one it has works until the new one is used")
        return .rekeyed(reply)
    }

    /// `unpair`: "Forget this Mac" on the iPhone. Only ever removes the
    /// device this connection authenticated as.
    private func handleUnpair(
        context: inout ConnectionContext, device: PairedDevice, live: LiveConnection
    ) throws -> WireMessage {
        guard capabilities.contains(SyncCapability.unpair), context.capabilities.contains(SyncCapability.unpair)
        else { throw ReplyError(.badRequest, "unpair was not announced by both sides") }
        registry.remove(deviceID: device.deviceID)
        // This connection is answered first, then closed.
        closeConnections(ofDevice: device.deviceID, keeping: live)
        context.close = true
        log("\(device.name ?? "device") unpaired itself (Forget this Mac on the iPhone)")
        delegate?.syncServerDevicesChanged(self)
        return .unpaired
    }

    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    // MARK: uploads

    private func partURL(_ id: String) -> URL {
        stagingDirectory.appendingPathComponent("\(id).part")
    }

    private func partManifestURL(_ id: String) -> URL {
        stagingDirectory.appendingPathComponent("\(id).manifest.json")
    }

    private var verifiedDirectory: URL {
        stagingDirectory.appendingPathComponent("verified", isDirectory: true)
    }

    private func verifiedManifestURL(_ id: String) -> URL {
        verifiedDirectory.appendingPathComponent("\(id).manifest.json")
    }

    private func verifiedFileURL(_ manifest: RecordingManifest) -> URL {
        verifiedDirectory.appendingPathComponent("\(manifest.id).\(manifest.fileExtension)")
    }

    private func verifiedManifest(_ id: String) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: verifiedManifestURL(id)),
            let manifest = try? WireJSON.decoder().decode(RecordingManifest.self, from: data),
            FileManager.default.fileExists(atPath: verifiedFileURL(manifest).path)
        else { return nil }
        return manifest
    }

    private func partialManifest(_ id: String) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: partManifestURL(id)) else { return nil }
        return try? WireJSON.decoder().decode(RecordingManifest.self, from: data)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    private func handleOffer(
        _ manifest: RecordingManifest, context: inout ConnectionContext, device: PairedDevice
    ) async throws -> WireMessage {
        if let problem = manifest.validationError() {
            throw ReplyError(.badRequest, problem)
        }
        // Idempotency: never take the same recording twice.
        if verifiedManifest(manifest.id) != nil {
            log("offer \(manifest.id.prefix(8))…: already verified here — skip")
            return .offerReply(OfferReplyMessage(recordingID: manifest.id, action: .skip, offset: manifest.byteCount))
        }
        if let delegate = self.delegate {
            let known = await delegate.syncServer(self, statusFor: [manifest.id])
            if let status = known.first(where: { $0.recordingID == manifest.id }),
                ![.unknown, .receiving].contains(status.state)
            {
                if status.state == .failed {
                    // The phone already sent this; offering it again after the
                    // Mac gave up is its Retry. The Mac still has the audio, so
                    // the answer stays `skip` — but re-queued first, so the
                    // `status` the phone asks for next is no longer terminal
                    // (sync-protocol.md § Retrying).
                    let retried = await delegate.syncServer(self, retryRequestedFor: manifest.id, from: device)
                    log("offer \(manifest.id.prefix(8))…: failed on the Mac; retry requested — "
                        + "\(retried.map { "now \($0.state.rawValue)" } ?? "not retried") — skip")
                } else {
                    log("offer \(manifest.id.prefix(8))…: Mac already has it (\(status.state.rawValue)) — skip")
                }
                return .offerReply(
                    OfferReplyMessage(recordingID: manifest.id, action: .skip, offset: manifest.byteCount))
            }
        }
        let resume: Int64? = try stagingLock.withLock {
            // Complete here and on its way to the engine (which may not list
            // it yet): taking it again would race that hand-off for the same
            // files. Checked under the staging lock, where `commit` claims.
            guard !isHandingOff(manifest.id) else { return nil }
            let part = partURL(manifest.id)
            if let staged = partialManifest(manifest.id),
                staged.sha256 == manifest.sha256, staged.byteCount == manifest.byteCount,
                let size = Self.fileSize(part), size <= manifest.byteCount
            {
                return size
            }
            // New recording, or the phone's file changed: start over.
            try? FileManager.default.removeItem(at: part)
            let data = try WireJSON.encoder().encode(manifest)
            try data.write(to: partManifestURL(manifest.id), options: .atomic)
            guard FileManager.default.createFile(
                atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw ReplyError(.internal, "cannot create the staging file") }
            return 0
        }
        guard let offset = resume else {
            log("offer \(manifest.id.prefix(8))…: being verified or handed off — skip")
            return .offerReply(OfferReplyMessage(recordingID: manifest.id, action: .skip, offset: manifest.byteCount))
        }
        context.offered[manifest.id] = manifest
        // No title: this line reaches a log file the user may share.
        log("offer \(manifest.id.prefix(8))… \(manifest.byteCount) bytes — send from \(offset)")
        emit(.uploadStarted(manifest, offset: offset, deviceID: device.deviceID))
        return .offerReply(OfferReplyMessage(recordingID: manifest.id, action: .send, offset: offset))
    }

    private func handleChunk(_ chunk: ChunkMessage, body: Data, context: ConnectionContext) throws -> WireMessage {
        guard let manifest = context.offered[chunk.recordingID] else {
            throw ReplyError(.unknownRecording, "offer \(chunk.recordingID) before sending chunks")
        }
        let received: Int64 = try stagingLock.withLock {
            // Another connection committed this recording; its bytes are
            // being hashed right now and must not move under the hash.
            guard !isHandingOff(manifest.id) else {
                throw ReplyError(.unknownRecording, "\(manifest.id) is being verified; offer it again")
            }
            let part = partURL(manifest.id)
            guard let size = Self.fileSize(part) else {
                throw ReplyError(.unknownRecording, "no staged upload for \(manifest.id); offer it again")
            }
            guard chunk.offset == size else {
                throw ReplyError(.offsetMismatch, "expected offset \(size)", received: size)
            }
            guard size + Int64(body.count) <= manifest.byteCount else {
                throw ReplyError(.tooLarge, "chunk runs past byteCount \(manifest.byteCount)")
            }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: body)
            return size + Int64(body.count)
        }
        emit(.uploadProgress(recordingID: manifest.id, received: received, total: manifest.byteCount))
        return .chunkAck(ChunkAckMessage(recordingID: manifest.id, received: received))
    }

    private func handleCommit(
        _ recordingID: String, context: inout ConnectionContext, device: PairedDevice
    ) async throws -> WireMessage {
        guard let manifest = context.offered[recordingID] else {
            throw ReplyError(.unknownRecording, "nothing offered with id \(recordingID)")
        }
        // One verification + hand-off per recording at a time. Whoever holds
        // the claim (another connection's commit, a re-delivery at launch) is
        // already taking this very recording to the engine; once is enough.
        // Claimed under the staging lock, so an offer or chunk for this ID on
        // another connection lands entirely before or entirely after it.
        let part = partURL(manifest.id)
        let claimed: Int64? = try stagingLock.withLock {
            guard beginHandOff(manifest.id) else {
                // Our bytes are a spare copy only if a verified one exists;
                // otherwise the part is the one the claim holder is reading.
                if verifiedManifest(manifest.id) != nil {
                    try? FileManager.default.removeItem(at: part)
                    try? FileManager.default.removeItem(at: partManifestURL(manifest.id))
                }
                return nil
            }
            guard let size = Self.fileSize(part) else {
                endHandOff(manifest.id)
                throw ReplyError(.unknownRecording, "no staged upload for \(manifest.id)")
            }
            return size
        }
        guard let size = claimed else {
            context.offered.removeValue(forKey: recordingID)
            log("commit \(manifest.id.prefix(8))…: already being handed off — not taken twice")
            return .committed(
                CommittedMessage(
                    status: RemoteStatus(
                        recordingID: manifest.id, state: .received,
                        detail: "Already being handed to the engine")))
        }
        defer { endHandOff(manifest.id) }

        // Hash with the staging lock released: for a multi-GB recording this
        // takes seconds, and the lock is what every other upload's chunks
        // wait on. The file cannot change meanwhile: while the claim is held
        // a new offer of this ID answers `skip`, a chunk for it is refused,
        // and the pruner leaves it alone.
        // byteCount + sha256 must both match; either mismatch discards the
        // partial and the client restarts from 0 (sync-protocol.md).
        let digest = size == manifest.byteCount ? try await hashFile(part).1 : nil
        let fileURL: URL = try stagingLock.withLock {
            guard let digest, digest == manifest.sha256 else {
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: partManifestURL(manifest.id))
                context.offered.removeValue(forKey: recordingID)
                let why = digest == nil
                    ? "size \(size) ≠ byteCount \(manifest.byteCount)" : "sha256 mismatch"
                log("commit \(manifest.id.prefix(8))…: \(why) — discarded")
                emit(.uploadFailed(recordingID: manifest.id, reason: "checksum mismatch"))
                throw ReplyError(.checksumMismatch, "\(why); upload discarded, restart from 0")
            }
            let destination = verifiedFileURL(manifest)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: part, to: destination)
            try? FileManager.default.removeItem(at: verifiedManifestURL(manifest.id))
            try FileManager.default.moveItem(
                at: partManifestURL(manifest.id), to: verifiedManifestURL(manifest.id))
            return destination
        }
        context.offered.removeValue(forKey: recordingID)
        log("commit \(manifest.id.prefix(8))…: sha256 verified")
        emit(.uploadVerified(manifest, deviceID: device.deviceID))
        let status: RemoteStatus
        if let delegate = self.delegate {
            status = await delegate.syncServer(self, didReceive: manifest, fileURL: fileURL, from: device)
        } else {
            status = RemoteStatus(recordingID: manifest.id, state: .received, detail: "No receiver attached")
        }
        // The delegate took ownership by moving the file; drop our record.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: verifiedManifestURL(manifest.id))
        }
        return .committed(
            CommittedMessage(status: status.limited(to: sharedCapabilities(context)).clampedForWire()))
    }

    // MARK: status + transcript

    /// The additive features this connection may use: the ones both this Mac
    /// and the phone announced.
    private func sharedCapabilities(_ context: ConnectionContext) -> Set<String> {
        context.capabilities.intersection(capabilities)
    }

    private func handleStatus(_ ids: [String], context: ConnectionContext) async throws -> WireMessage {
        guard ids.count <= 1000 else { throw ReplyError(.badRequest, "at most 1000 ids per request") }
        guard ids.allSatisfy(SyncConstants.isValidID) else {
            throw ReplyError(.badRequest, "invalid recording id")
        }
        // The delegate fills in every extra; a phone that did not announce a
        // feature gets the status exactly as v1 had it.
        let shared = sharedCapabilities(context)
        return .statusReply(
            StatusReplyMessage(
                items: await statuses(for: ids).map { $0.limited(to: shared).clampedForWire() }))
    }

    /// Delegate answers, overlaid with what only the server knows (partial
    /// and verified-but-unclaimed uploads).
    public func statuses(for ids: [String]) async -> [RemoteStatus] {
        var byID: [String: RemoteStatus] = [:]
        if let delegate = self.delegate, !ids.isEmpty {
            for status in await delegate.syncServer(self, statusFor: ids) {
                byID[status.recordingID] = status
            }
        }
        return ids.map { id in
            if let status = byID[id], status.state != .unknown { return status }
            if verifiedManifest(id) != nil {
                return RemoteStatus(recordingID: id, state: .received, detail: "Waiting for the huske engine")
            }
            if let manifest = partialManifest(id), let size = Self.fileSize(partURL(id)) {
                let progress = manifest.byteCount > 0 ? Double(size) / Double(manifest.byteCount) : 0
                return RemoteStatus(
                    recordingID: id, state: .receiving,
                    detail: "\(size) of \(manifest.byteCount) bytes",
                    updatedAt: Self.modificationDate(partURL(id)) ?? Date(),
                    progress: progress)
            }
            return byID[id] ?? .unknown(id)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func handleTranscript(_ id: String, context: ConnectionContext) async throws -> WireMessage {
        guard SyncConstants.isValidID(id) else { throw ReplyError(.badRequest, "invalid recording id") }
        let delegate = self.delegate
        if let text = await delegate?.syncServer(self, transcriptFor: id) {
            return .transcriptReply(
                TranscriptReplyMessage(recordingID: id, available: true),
                body: Self.utf8Prefix(text, maxBytes: SyncConstants.maxBodyLength))
        }
        // The parts of a recording the Mac gave up on — only for a phone that
        // knows to tell them from a whole transcript; any other is answered
        // as before (`available: false`).
        if sharedCapabilities(context).contains(SyncCapability.partialTranscript),
            let text = await delegate?.syncServer(self, partialTranscriptFor: id)
        {
            return .transcriptReply(
                TranscriptReplyMessage(recordingID: id, available: true, partial: true),
                body: Self.utf8Prefix(text, maxBytes: SyncConstants.maxBodyLength))
        }
        return .transcriptReply(TranscriptReplyMessage(recordingID: id, available: false), body: Data())
    }

    /// UTF-8 bytes of `text`, cut at a character boundary to fit `maxBytes`.
    static func utf8Prefix(_ text: String, maxBytes: Int) -> Data {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return data }
        let marker = "\n\n[… truncated on the Mac]\n"
        var budget = maxBytes - marker.utf8.count
        var result = ""
        for character in text {
            let size = String(character).utf8.count
            guard size <= budget else { break }
            result.append(character)
            budget -= size
        }
        return Data((result + marker).utf8)
    }

    // MARK: plumbing

    private func emit(_ event: SyncServerEvent) {
        onEvent?(event)
    }

    func log(_ message: String) {
        logHandler?(message)
    }
}

extension RemoteStatus {
    /// `detail` cut to `SyncConstants.maxStatusDetailBytes` of UTF-8 so one
    /// verbose engine error cannot push a status reply past the header limit.
    func clampedForWire() -> RemoteStatus {
        guard let detail, detail.utf8.count > SyncConstants.maxStatusDetailBytes else { return self }
        let ellipsis = "…"
        var budget = SyncConstants.maxStatusDetailBytes - ellipsis.utf8.count
        var cut = ""
        for character in detail {
            let size = String(character).utf8.count
            guard size <= budget else { break }
            cut.append(character)
            budget -= size
        }
        return replacingDetail(cut + ellipsis)
    }
}

/// Remembers which PSK identity each handshake selected, so a connection can
/// check that its `hello` names the same device it authenticated as.
private final class HandshakeIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(metadata: sec_protocol_metadata_t, identity: String, at: Date)] = []

    func record(_ metadata: sec_protocol_metadata_t, identity: String) {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-60)
            entries.removeAll { $0.at < cutoff }
            entries.append((metadata, identity, Date()))
        }
    }

    func take(_ metadata: sec_protocol_metadata_t) -> String? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.metadata === metadata }) else { return nil }
            return entries.remove(at: index).identity
        }
    }
}
