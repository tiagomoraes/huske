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
    private var restartInFlight = false
    private var boundPort: UInt16?
    private var running = false
    private var _lastError: String?
    private var _advertise = true
    private var connections: [ObjectIdentifier: LiveConnection] = [:]
    private var pruneTimer: DispatchSourceTimer?
    private let identities = HandshakeIdentities()

    private final class LiveConnection: @unchecked Sendable {
        let framed: FramedConnection
        var deviceID: String?
        init(_ framed: FramedConnection) { self.framed = framed }
    }

    /// Idle time before a silent connection is closed.
    static let idleTimeout: TimeInterval = 120

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

    public var isRunning: Bool { lock.withLock { running } }

    /// The bound port once the listener is ready.
    public var port: UInt16? { lock.withLock { running ? boundPort : nil } }

    /// Why the listener is not listening, when it is not.
    public var lastError: String? { lock.withLock { _lastError } }

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
        let generation = lock.withLock { listenerGeneration }
        do {
            try startListener(port: requestedPort, generation: generation, fallbackToEphemeral: false)
        } catch {
            lock.withLock { running = false }
            throw error
        }
        startPruneTimer()
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
        old?.cancel()
        timer?.cancel()
        for connection in live { connection.framed.cancel() }
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

    /// Mint + register a pending invite (restarts the listener with the new key).
    public func makeInvite() -> PairingInvite {
        registry.pruneExpired()
        let invite = PairingInvite.mint(macID: registry.macID, macName: macName)
        registry.addPending(invite)
        log("pairing invite minted for device \(invite.deviceID.prefix(8))…")
        restartListener()
        return invite
    }

    /// Forget a device (restarts the listener without its key).
    public func removeDevice(_ deviceID: String) {
        registry.remove(deviceID: deviceID)
        let doomed: [LiveConnection] = lock.withLock {
            connections.values.filter { $0.deviceID == deviceID }
        }
        for connection in doomed { connection.framed.cancel() }
        log("device \(deviceID.prefix(8))… removed")
        restartListener()
        delegate?.syncServerDevicesChanged(self)
    }

    // MARK: listener

    private func startListener(port: UInt16, generation: Int, fallbackToEphemeral: Bool) throws {
        let keys = registry.activeKeys()
        let registry = self.registry
        let identities = self.identities
        let params = TLSPSK.serverParameters(keys: keys, queue: queue) { metadata, identity in
            guard let device = registry.device(id: identity), !device.isExpired() else {
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
        let advertise: Bool = lock.withLock { _advertise }
        if advertise {
            var txt = NWTXTRecord()
            txt["v"] = String(SyncConstants.protocolVersion)
            txt["mac"] = registry.macID
            listener.service = NWListener.Service(
                name: macName, type: SyncConstants.serviceType, domain: nil, txtRecord: txt)
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
            return true
        }
        guard current else { return }
        listener.start(queue: queue)
        log("listener starting with \(keys.count) device key(s)\(port == 0 ? "" : " on port \(port)")")
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
            lock.withLock {
                boundPort = bound
                restartInFlight = false
                _lastError = nil
            }
            if let bound {
                log("listening on port \(bound)")
                emit(.listening(port: bound))
            }
        case .failed(let error):
            listener.cancel()
            guard isCurrent else { return }
            if fallbackToEphemeral, port != 0 {
                // The previous port could not be re-bound; any port will do —
                // phones resolve the Mac through Bonjour every time.
                log("could not re-bind port \(port) (\(error)); using an ephemeral port")
                try? startListener(port: 0, generation: generation, fallbackToEphemeral: false)
                return
            }
            let message = "listener failed: \(error)"
            lock.withLock {
                _lastError = message
                self.listener = nil
                boundPort = nil
                restartInFlight = false
            }
            log(message)
            emit(.listenerFailed(message))
        default:
            break
        }
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
                self.lock.withLock {
                    self._lastError = "listener restart failed: \(error)"
                    self.restartInFlight = false
                }
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
            guard !removed.isEmpty else { return }
            self.log("expired \(removed.count) unused pairing invite(s)")
            self.restartListener()
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
            guard let manifest = verifiedManifest(id) else { continue }
            let fileURL = verifiedFileURL(manifest)
            // Which phone sent it isn't kept past commit; its name is in the manifest.
            let device = PairedDevice(deviceID: "redelivery", key: Data(), name: manifest.deviceName)
            log("re-delivering verified upload \(id.prefix(8))…")
            _ = await delegate.syncServer(self, didReceive: manifest, fileURL: fileURL, from: device)
            if !fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: verifiedManifestURL(id))
            }
        }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        let framed = FramedConnection(connection, label: "server-conn")
        let live = LiveConnection(framed)
        let accepted: Bool = lock.withLock {
            guard running else { return false }
            connections[ObjectIdentifier(live)] = live
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        Task {
            await self.serve(live)
            self.lock.withLock { _ = self.connections.removeValue(forKey: ObjectIdentifier(live)) }
        }
    }

    private struct ConnectionContext {
        var device: PairedDevice?
        var tlsIdentity: String?
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
                message = try await framed.receive(timeout: Self.idleTimeout)
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
            do {
                try await framed.send(reply)
            } catch {
                break
            }
        }
        if let deviceID = context.device?.deviceID {
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
                return try await handleStatus(request.recordingIDs)
            case .transcript(let request):
                return try await handleTranscript(request.recordingID)
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
        guard hello.protocolVersion == SyncConstants.protocolVersion else {
            context.close = true
            return .error(
                ErrorMessage(
                    code: .versionMismatch,
                    message: "this Mac speaks protocol v\(SyncConstants.protocolVersion), the phone v\(hello.protocolVersion)"))
        }
        // Fail closed: a hello we cannot tie to the PSK the handshake used is
        // refused, so one paired key can never speak for another device.
        guard let tlsIdentity = context.tlsIdentity, tlsIdentity == hello.deviceID else {
            context.close = true
            log("hello deviceID does not match the TLS identity — refusing")
            return .error(ErrorMessage(code: .badRequest, message: "deviceID does not match the TLS identity"))
        }
        guard let existing = registry.device(id: hello.deviceID), !existing.isExpired() else {
            context.close = true
            return .error(ErrorMessage(code: .badRequest, message: "unknown device"))
        }
        let name = Self.clean(hello.deviceName)
        let model = Self.clean(hello.deviceModel)
        var changed: Bool
        if existing.isPaired {
            changed = registry.touch(deviceID: existing.deviceID, name: name, model: model)
        } else {
            guard registry.markPaired(deviceID: existing.deviceID, name: name, model: model) else {
                context.close = true
                return .error(ErrorMessage(code: .badRequest, message: "pairing invite expired"))
            }
            changed = true
        }
        let device = registry.device(id: existing.deviceID) ?? existing
        context.device = device
        lock.withLock { live.deviceID = device.deviceID }
        if !existing.isPaired {
            log("paired with \(device.name ?? device.deviceID)")
            emit(.devicePaired(device))
        }
        emit(.deviceConnected(device))
        log("hello from \(device.name ?? device.deviceID) (\(device.model ?? "?"), app \(hello.appVersion))")
        let delegate = self.delegate
        if changed { delegate?.syncServerDevicesChanged(self) }
        return .welcome(
            Welcome(
                protocolVersion: SyncConstants.protocolVersion,
                macID: registry.macID,
                macName: macName,
                serverVersion: serverVersion,
                engineAvailable: delegate?.syncServerEngineAvailable(self) ?? false))
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
                log("offer \(manifest.id.prefix(8))…: Mac already has it (\(status.state.rawValue)) — skip")
                return .offerReply(
                    OfferReplyMessage(recordingID: manifest.id, action: .skip, offset: manifest.byteCount))
            }
        }
        let offset: Int64 = try stagingLock.withLock {
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
        context.offered[manifest.id] = manifest
        log("offer \(manifest.id.prefix(8))… \"\(manifest.title)\" \(manifest.byteCount) bytes — send from \(offset)")
        emit(.uploadStarted(manifest, offset: offset, deviceID: device.deviceID))
        return .offerReply(OfferReplyMessage(recordingID: manifest.id, action: .send, offset: offset))
    }

    private func handleChunk(_ chunk: ChunkMessage, body: Data, context: ConnectionContext) throws -> WireMessage {
        guard let manifest = context.offered[chunk.recordingID] else {
            throw ReplyError(.unknownRecording, "offer \(chunk.recordingID) before sending chunks")
        }
        let received: Int64 = try stagingLock.withLock {
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
        let fileURL: URL = try stagingLock.withLock {
            let part = partURL(manifest.id)
            guard let size = Self.fileSize(part) else {
                throw ReplyError(.unknownRecording, "no staged upload for \(manifest.id)")
            }
            // byteCount + sha256 must both match; either mismatch discards
            // the partial and the client restarts from 0 (sync-protocol.md).
            let digest = size == manifest.byteCount ? try FileHashing.sha256(of: part).1 : nil
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
        return .committed(CommittedMessage(status: status))
    }

    // MARK: status + transcript

    private func handleStatus(_ ids: [String]) async throws -> WireMessage {
        guard ids.count <= 1000 else { throw ReplyError(.badRequest, "at most 1000 ids per request") }
        guard ids.allSatisfy(SyncConstants.isValidID) else {
            throw ReplyError(.badRequest, "invalid recording id")
        }
        return .statusReply(StatusReplyMessage(items: await statuses(for: ids)))
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

    private func handleTranscript(_ id: String) async throws -> WireMessage {
        guard SyncConstants.isValidID(id) else { throw ReplyError(.badRequest, "invalid recording id") }
        guard let text = await delegate?.syncServer(self, transcriptFor: id) else {
            return .transcriptReply(TranscriptReplyMessage(recordingID: id, available: false), body: Data())
        }
        return .transcriptReply(
            TranscriptReplyMessage(recordingID: id, available: true),
            body: Self.utf8Prefix(text, maxBytes: SyncConstants.maxBodyLength))
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
