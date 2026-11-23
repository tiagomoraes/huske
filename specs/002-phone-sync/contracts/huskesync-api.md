# Contract: `HuskeSync` Swift library API (v1)

A SwiftPM library target in `macos/Package.swift` (`macos/Sources/HuskeSync`),
platforms macOS 14+ and iOS 17+, with no third-party dependencies (Foundation,
Network, CryptoKit, Security only). The iPhone app (`ios/`) depends on it as a local
package product. The Mac app (`Huske` target) depends on it too. It implements
[sync-protocol.md](sync-protocol.md). Everything public is `Sendable`.

The signatures below are the contract between the iPhone app and the library.
Implementations may add members, but must not rename or remove these.

```swift
import Foundation

// MARK: - Shared models

public enum SyncConstants {
    public static let serviceType = "_huske-sync._tcp"
    /// The highest protocol version this build speaks; a connection uses the
    /// lower of the two peers' (sync-protocol.md § Versioning and capabilities).
    public static let protocolVersion = 1
    /// Additive features this build announces in `hello` / `welcome`.
    public static let capabilities: [String] = [
        SyncCapability.rekey, SyncCapability.unpair,
        SyncCapability.partialTranscript, SyncCapability.retryState,
    ]
    public static let urlScheme = "huske"
}

/// Names of the additive features (sync-protocol.md § Capabilities). A
/// feature is used only when both sides announced it.
public enum SyncCapability {
    public static let rekey = "pairing.rekey"     // rekey / rekeyed
    public static let unpair = "pairing.unpair"   // unpair / unpaired
    // partialTranscript and retryState: see the extension further down.
}

/// A PSK identity and its key. The pairing link carries the first one;
/// `SyncSession.rekey()` returns the one that replaces it.
public struct DeviceCredential: Codable, Sendable, Equatable {
    public let deviceID: String      // PSK identity; the phone's deviceID once in use
    public let key: Data             // 32-byte PSK
    public let issuedAt: Date
    public init(deviceID: String, key: Data, issuedAt: Date = .now)
}

/// What the QR code / pairing link carries. Minted by the Mac.
public struct PairingInvite: Codable, Sendable, Equatable {
    public let macID: String
    public let macName: String
    public let deviceID: String      // PSK identity for this phone
    public let key: Data             // 32-byte PSK
    public let expiresAt: Date

    public init(macID: String, macName: String, deviceID: String, key: Data, expiresAt: Date)
    /// Mint a fresh invite (random deviceID + 32-byte key, 10-minute expiry).
    public static func mint(macID: String, macName: String, now: Date = .now) -> PairingInvite
    /// `huske://pair?v=1&mac=…&name=…&id=…&exp=…&key=…`
    public var url: URL { get }
    /// Parses a pairing URL (also accepts the URL embedded in surrounding text).
    public init?(url: URL)
    public init?(string: String)
}

/// The iPhone's record of the Mac it is paired with (stored in the Keychain).
public struct PairedMac: Codable, Sendable, Equatable {
    public let macID: String
    public var macName: String
    public let deviceID: String
    public let key: Data
    public let pairedAt: Date
    /// A credential the Mac issued (`rekey`) that the phone has not proven
    /// yet. Tried first; `deviceID` / `key` stay until the Mac has answered a
    /// `hello` made with it. Optional on disk: older stored pairings load.
    public var pending: DeviceCredential?
    /// When `key` last came from the Mac over the paired connection (nil =
    /// it is still the pairing link's).
    public var rotatedAt: Date?
    public init(invite: PairingInvite, pairedAt: Date = .now)
    public init(macID: String, macName: String, deviceID: String, key: Data, pairedAt: Date,
                pending: DeviceCredential? = nil, rotatedAt: Date? = nil)
    /// The link's key is in use and no replacement is on its way.
    public var needsRekey: Bool { get }
    /// This pairing as it connects with `pending` (nil when there is none).
    public var usingPending: PairedMac? { get }
    /// `pending` proved itself: it becomes `deviceID` / `key`.
    public func promotingPending(now: Date = .now) -> PairedMac
}

public struct RecordingManifest: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public let startedAt: Date
    public var durationSeconds: Double
    public let byteCount: Int64
    public let sha256: String        // lowercase hex
    public let fileExtension: String // "m4a"
    public let contentType: String   // "audio/mp4"
    public let sampleRate: Double
    public let channels: Int
    public let timeZone: String      // IANA identifier
    public let deviceName: String
    public init(...)                 // memberwise
    /// Hashes the file (streaming) and fills byteCount + sha256.
    public static func make(id: String, title: String, startedAt: Date,
                            durationSeconds: Double, fileURL: URL, sampleRate: Double,
                            channels: Int, timeZone: TimeZone, deviceName: String) throws -> RecordingManifest
}

public enum RemoteState: String, Codable, Sendable {
    case unknown, receiving, received, queued, transcribing, transcribed, failed
    public var isTerminal: Bool { get }   // transcribed || failed
}

public struct RemoteStatus: Codable, Sendable, Equatable {
    public let recordingID: String
    public let state: RemoteState
    public let detail: String?
    public let updatedAt: Date
    public let progress: Double?
    // Optional extras (nil = absent on the wire). Each is carried only when
    // both sides announced its capability; see sync-protocol.md § RemoteStatus.
    public var partial: Bool?             // transcript.partial
    public var partsDone: Int?
    public var partsTotal: Int?
    public var retrying: Bool?            // status.retry
    public var attempt: Int?
    public var maxAttempts: Int?
    public init(recordingID: String, state: RemoteState, detail: String? = nil,
                updatedAt: Date = .now, progress: Double? = nil)   // extras start nil
    public func withPartialTranscript(done: Int, total: Int) -> RemoteStatus
    public func withRetry(attempt: Int? = nil, maxAttempts: Int? = nil) -> RemoteStatus
    /// Drops the extras of every capability not in the set; never the fields above.
    public func limited(to capabilities: Set<String>) -> RemoteStatus
}

extension SyncCapability {
    public static let partialTranscript = "transcript.partial"
    public static let retryState = "status.retry"
}

/// What `SyncSession.fetchTranscript` brought back.
public struct FetchedTranscript: Sendable, Equatable {
    public let text: String
    public let isPartial: Bool            // the parts of a recording the Mac gave up on
    public init(text: String, isPartial: Bool = false)
}

public struct Welcome: Codable, Sendable, Equatable {
    public let protocolVersion: Int       // what this connection speaks: min(phone, Mac)
    public let macID: String
    public let macName: String
    public let serverVersion: String
    public let engineAvailable: Bool
    public let capabilities: [String]     // [] from a Mac that predates capabilities
    public init(protocolVersion: Int, macID: String, macName: String, serverVersion: String,
                engineAvailable: Bool, capabilities: [String] = [])
}

public enum SyncError: Error, Sendable, Equatable {
    case macNotFound          // Bonjour did not find the paired Mac in time
    case handshakeFailed(String)  // TLS/PSK failure (e.g. unpaired on the Mac)
    case connectionClosed
    case protocolError(code: String, message: String)
    case checksumMismatch
    case timeout
    case io(String)                // local: the recording's file could not be read
    case network(NetworkFailure)   // the way to the Mac, never a file
}

/// Why the network would not carry a connection to the Mac.
public enum NetworkFailure: Sendable, Equatable, CustomStringConvertible {
    case refused                  // ECONNREFUSED: the Mac is up, Huske is not listening
    case unreachable(String)      // no route, network or host down
    case nameNotResolved(String)  // DNS / Bonjour
    case other(String)
}

/// Why Bonjour could not look for the Mac at all (as opposed to looking and
/// not finding it, `SyncError.macNotFound`). Its own type so exhaustive
/// switches over `SyncError` keep compiling. `LocalizedError`.
public enum DiscoveryIssue: Error, Sendable, Equatable {
    case localNetworkDenied            // Local Network privacy said no
    case browsingUnavailable(String)   // Bonjour not working right now
}

// MARK: - iPhone side

/// How the phone sees, or reaches, the Mac.
public enum SyncRoute: String, Sendable, Hashable, CaseIterable {
    case wifi          // the Wi-Fi network both are on
    case wired
    case peerToPeer    // straight between the two (AWDL), no shared network
    case loopback
    case other
}

/// What the Bonjour browse knows about the paired Mac at one moment.
public struct MacPresence: Sendable, Equatable {
    public let isBrowsing: Bool          // start() without a later stop()
    public let issue: DiscoveryIssue?    // why it can't look; nil while it can
    public let endpoint: NWEndpoint?     // the Mac's service while visible
    public let routes: [SyncRoute]       // how it was seen
    public var isVisible: Bool { get }   // endpoint != nil
    public init(isBrowsing: Bool = false, issue: DiscoveryIssue? = nil,
                endpoint: NWEndpoint? = nil, routes: [SyncRoute] = [])
}

/// Watches Bonjour for one paired Mac. `isReachable` drives the UI dot and
/// triggers uploads.
/// A failed browser (iOS resets a suspended app's mDNSResponder connection)
/// is replaced with backoff, 1 → 30 s, until `stop()`.
public final class MacPresenceMonitor: @unchecked Sendable {
    public init(macID: String)
    public func start()
    public func stop()
    /// Emits whenever reachability changes (current value first).
    public var updates: AsyncStream<Bool> { get }
    public var isReachable: Bool { get }
    /// Why the Mac can't be looked for right now; nil while browsing works.
    public var issue: DiscoveryIssue? { get }
    /// Emits whenever `issue` changes (current value first).
    public var issueUpdates: AsyncStream<DiscoveryIssue?> { get }
    /// Browse state, issue and the Mac's endpoint in one value. While there is
    /// an `issue`, no endpoint is reported.
    public var presence: MacPresence { get }
    public var endpoint: NWEndpoint? { get }   // presence.endpoint
    /// Emits whenever `presence` changes (current value first), in order: the
    /// Mac appeared, left or is seen another way; browsing started, stopped
    /// or hit an issue.
    public var presenceUpdates: AsyncStream<MacPresence> { get }
}

public final class SyncClient: Sendable {
    public init(pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String)
    /// `installID`: stable for this install of the app (`hello.installID`).
    /// Pass it only for the pairing the phone keeps — the Mac removes the
    /// install's other entries when it sees it — and nil while trying a new
    /// code next to a pairing that works. `capabilities`: what to announce.
    public init(pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String,
                installID: String?, capabilities: [String] = SyncConstants.capabilities)
    /// Browse for the paired Mac (≤ `timeout`), connect with TLS-PSK, send hello.
    /// Throws `SyncError`, or `DiscoveryIssue` when Bonjour can't browse
    /// (Local Network denied fails at once instead of after `timeout`).
    public func connect(timeout: TimeInterval = 8) async throws -> SyncSession
    /// The same, to an endpoint the caller already holds (normally
    /// `MacPresenceMonitor.presence.endpoint`): no second browse. The
    /// `welcome` must still come from the paired Mac (`wrong_mac` otherwise).
    public func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> SyncSession
}

public final class SyncSession: Sendable {
    public var welcome: Welcome { get }
    /// How the session reaches the Mac (`.wifi`, `.peerToPeer`…).
    public var route: SyncRoute { get }
    /// Whether both sides announced `capability`: only then may it be used.
    public func supports(_ capability: String) -> Bool
    /// `rekey`: a credential to replace the one this session used. Store it
    /// as `PairedMac.pending`, then connect with it; the Mac accepts the old
    /// one until it has seen the new one used. Throws
    /// `protocolError("unsupported")` (nothing is sent) unless both sides
    /// announced `pairing.rekey`, `protocolError("unavailable")` when the Mac
    /// has none to give right now.
    public func rekey() async throws -> DeviceCredential
    /// `unpair`: the Mac forgets this iPhone and closes. `unsupported` as above.
    public func unpair() async throws
    /// Offer → (resume from offset | skip) → chunks → commit. Chunks start at
    /// 256 KiB and follow the link, 64 KiB … 1 MiB (sync-protocol.md § Chunk
    /// size). `progress(sent, total)` is called on an arbitrary queue.
    /// Honors task cancellation between chunks (throws `CancellationError`;
    /// the session stays usable and a later upload resumes).
    public func upload(manifest: RecordingManifest, fileURL: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus
    /// Any number of IDs; sent in batches of 50 so each reply fits a frame.
    public func status(_ recordingIDs: [String]) async throws -> [RemoteStatus]
    /// A finished recording's transcript. Never a partial one: nil then.
    public func transcript(_ recordingID: String) async throws -> String?
    /// The whole transcript, or (transcript.partial on both sides) the parts
    /// the Mac transcribed of a recording it gave up on. `status` and
    /// `upload` return statuses already limited to the shared capabilities.
    public func fetchTranscript(_ recordingID: String) async throws -> FetchedTranscript?
    /// Dropping a session without `close()` still closes its connection.
    public func close() async
    // Every request: one that fails in transit (`timeout`, `connectionClosed`,
    // `io`, an unreadable reply) ends the session — its connection is closed
    // and `close()` returns at once; connect again. An `error` *reply* from
    // the Mac (`checksumMismatch`, `protocolError`) leaves it usable.
    // Cancelling a request's task while it is in flight does the same
    // (Network.framework I/O ignores cancellation, and a late reply could not
    // be told from the next one's) and throws `CancellationError`; a task
    // already cancelled when it asks throws without touching the connection.
}

// MARK: - Mac side

/// One phone known to the Mac (pending or paired).
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let key: Data
    public var name: String?          // from hello
    public var model: String?
    public let createdAt: Date
    public var pairedAt: Date?        // nil = pending invite
    public var lastSeenAt: Date?
    public var expiresAt: Date?       // pending only
    public var installID: String?     // from hello; nil for apps that send none
    /// Issued by `rekey`, not used yet: accepted next to `deviceID` / `key`
    /// until its first `hello` makes it the device's only credential.
    public var successor: DeviceCredential?
    public var rotatedAt: Date?       // nil = `key` is still the pairing link's
    public var isPaired: Bool { get }
}

/// Persists the Mac identity + devices. File-backed, 0600 permissions.
public final class DeviceRegistry: @unchecked Sendable {
    public init(fileURL: URL)
    public var macID: String { get }               // minted on first use, persisted
    public func devices() -> [PairedDevice]
    public func addPending(_ invite: PairingInvite)
    public func remove(deviceID: String)
    // plus internal mutators used by the server (markPaired, touch, prune expired)
}

public protocol SyncServerDelegate: AnyObject, Sendable {
    /// A recording finished uploading and its checksum verified. `fileURL` lives
    /// in the server's staging directory. The delegate takes ownership (move it
    /// to the engine inbox) and returns the new status.
    func syncServer(_ server: SyncServer, didReceive manifest: RecordingManifest,
                    fileURL: URL, from device: PairedDevice) async -> RemoteStatus
    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus]
    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String?
    /// Pairing completed or a device's name changed (UI refresh).
    func syncServerDevicesChanged(_ server: SyncServer)
    /// Whether the Mac currently has a usable engine (reported in `welcome`).
    func syncServerEngineAvailable(_ server: SyncServer) -> Bool
    /// The phone offered a recording again that the Mac holds as `failed`: its
    /// Retry (sync-protocol.md § After the upload). Re-queue it and return the
    /// new status, or nil. Optional: the default implementation returns nil.
    func syncServer(_ server: SyncServer, retryRequestedFor recordingID: String,
                    from device: PairedDevice) async -> RemoteStatus?
    /// The transcribed parts of a recording the Mac gave up on, or nil. Asked
    /// only for a phone that announced `transcript.partial`, after
    /// `transcriptFor` returned nil. Optional: the default returns nil.
    /// `statusFor` returns every extra; the server holds back the ones the
    /// phone did not announce.
    func syncServer(_ server: SyncServer, partialTranscriptFor recordingID: String) async -> String?
}

/// Whether paired iPhones can find and reach this Mac right now.
public enum SyncServerHealth: Sendable, Equatable {
    case stopped
    case starting                    // binding the port, announcing the Mac
    case listening(port: UInt16)     // bound AND the advert is confirmed
    case notAdvertising(Reason)      // listener alive, phones cannot find it
    case recovering(Reason)          // listener failed, being rebuilt (1 → 30 s)
    public enum Reason: Sendable, Equatable {
        case localNetworkDenied, noNetwork, advertNotRegistered, other(String)
    }
    public var isReachable: Bool { get }   // .listening
}

public final class SyncServer: @unchecked Sendable {
    public init(registry: DeviceRegistry, stagingDirectory: URL, macName: String,
                serverVersion: String, port: UInt16 = 0)  // 0 = ephemeral
    public weak var delegate: SyncServerDelegate?
    public func start() throws
    public func stop()
    public var isRunning: Bool { get }
    public var port: UInt16? { get }
    /// The state above. Unlike `port`, `.listening` means the advert is up too.
    public var health: SyncServerHealth { get }
    /// Called on every change of `health`, on an arbitrary queue.
    public var onHealthChange: (@Sendable (SyncServerHealth) -> Void)? { get set }
    /// The Mac woke, the network changed, the user is looking: verify that
    /// phones can still find this Mac and repair it now. Debounced; cheap
    /// when all is well. Network changes call it by themselves.
    public func recheck(reason: String)
    /// Paired devices with a connection open right now.
    public var connectedDeviceIDs: Set<String> { get }
    /// Mint + register a pending invite. Uses one of the listener's spare
    /// slots (64 per listener; a pairing takes two, the second for `rekey`),
    /// so the listener and its Bonjour advert stay up. Below 16 the listener
    /// is replaced at a quiet moment (nothing connected, nothing for 60 s, no
    /// code waiting); only with none left is it replaced on the spot.
    public func makeInvite() -> PairingInvite
    /// Forget a device: closes its connections; the handshake refuses it from
    /// then on. The listener is not replaced.
    public func removeDevice(_ deviceID: String)
    /// Hand verified uploads whose hand-off never completed to the delegate
    /// again. A recording is with the delegate at most once at a time: one a
    /// commit or another call is handing over right now is left alone.
    public func redeliverVerified() async
}
```

Listener health is reported through `onEvent`: `.listening(port:)` when ready,
`.listenerFailed(message)` when it fails **or** is waiting (e.g. Local Network
access denied; `lastError` says which). A failed listener restarts itself with
backoff (1, 2, 4 … 30 s) and emits `.listening` again; `start()` need not be
called again.

`.listening(port:)` only says the port is bound. `health` is the answer to "can
a phone reach this Mac": it becomes `.listening` once
`serviceRegistrationUpdateHandler` confirms the Bonjour registration. A bound
listener whose advert is not confirmed within 10 s, or is withdrawn, reports
`.notAdvertising(.advertNotRegistered)` and is rebuilt on the same backoff until
the advert takes. `recheck(reason:)` skips the wait: a listener that is down or
waiting is rebuilt at once, and a healthy one is verified by browsing for its
own advert (rebuilt only if Bonjour answers and the advert is not there). A
repeating failure is logged for its first three rounds, then every tenth.

`PairedDevice.lastSeenAt` moves on every request, not just `hello` (written to
disk at most every 30 s and when the connection closes).

`SyncError.handshakeFailed` means the key was refused. A TLS error after the
handshake completed surfaces as `.connectionClosed` (retry and resume). A
connection that closes after TLS and before `welcome` also reads as
`.handshakeFailed` — the two cannot be told apart — which is why a caller
holding two keys mid-rotation never drops one on a refusal alone
(sync-protocol.md § Key rotation).

`SyncError.network` is every failure of the way to the Mac: a refused port
(`.refused`), no route (`.unreachable`), a name that did not resolve
(`.nameNotResolved`). `SyncError.io` is left for what is local: the
recording's file could not be opened or read, or is shorter than its
manifest. The two used to share `.io`, and the app had to guess which it was
by looking for the file.

**Key rotation, in API terms** (the app owns the storage, the library the
wire):

```swift
let session = try await client.connect(to: endpoint)
if pairing.needsRekey, session.supports(SyncCapability.rekey) {
    var waiting = pairing
    waiting.pending = try await session.rekey()
    try store.save(waiting)                       // before it is used
    let fresh = try await SyncClient(pairing: waiting.usingPending!, …).connect(to: endpoint)
    try store.save(waiting.promotingPending())    // the Mac answered: it is the key now
}
// Later connections: `usingPending` first whenever `pending` is set.
```

While connecting, a *path* error (no route yet, the interface still coming up,
the Bonjour name not resolved) is given about 3 s to clear, because
Network.framework retries by itself when the path changes; if it doesn't, the
attempt fails with that error. An answer from the other side — a refused port,
a TLS rejection — still fails at once.

That "at once" needs a concrete address. Network.framework never reports a TLS
rejection (or a refused port) on a connection to a Bonjour *service* endpoint:
it stays "preparing" until the caller's timeout, so a forgotten key read as
`.timeout` after 8 s although the Mac had refused in 130 ms. `connect` therefore
resolves a service endpoint first — a UDP "connection", which resolves the name
without sending a packet — and opens the TLS connection to the address behind
it; a rejected key is `.handshakeFailed` within milliseconds. That address
gets 3 s. If it gives no answer at all (no path, or silence), or the name does
not resolve within 2 s, the service endpoint itself gets the rest of the time,
as before: Network.framework then tries every address the Mac has. A refusal
or a rejection from the address is final and is not tried again.

`MacPresenceMonitor` is the one browser the iPhone app keeps: it connects with
`connect(to: presence.endpoint)` and never browses per attempt. The app decides
when to look (`start()` / `stop()`); see `ios/README.md` § Sync.

## Test hooks

`SyncServer` (all `@_spi(Testing)`): `simulateListenerState(_:)` and
`simulateServiceRegistration(_:)` deliver a listener state or an advert change
as Network.framework would; `simulatesAdvertRegistration` expects an advert
without registering one, so tests need no mDNS; `advertGrace`,
`recheckDebounce`, `retryDelayOverride` and `advertProbe` shorten or replace the
timers and the Bonjour self-check.

`SyncClient` must be usable in `swift test` against a `SyncServer` in the same
process over loopback/Bonjour. If Bonjour is unreliable in CI, an internal or
`@_spi(Testing)` initializer may connect to an explicit `NWEndpoint` (host +
port) instead.

Failure tests run against a real server through `FaultProxy`
(`macos/Tests/HuskeSyncTests/FaultProxy.swift`), a loopback relay that sees
only TLS ciphertext and can stall, sever, black-hole, delay, or damage one TLS
record of a connection. The timeouts those tests would otherwise wait out are
injectable: the `@_spi(Testing)` `SyncClient` initializer takes
`requestTimeout:` (default `SyncSession.requestTimeout`, 30 s) and
`@_spi(Testing) SyncServer.idleTimeout` replaces the 120 s idle close.
`chunking: .fixed(n)` on the same initializer pins the upload chunk size (the
fault tests place faults between two particular chunks; `ThroughputTests`
measures fixed against adaptive through the proxy's latency mode), and
`installID:` / `capabilities:` let a test be an older iPhone app.
`@_spi(Testing) SyncServer.capabilities` does the same for an older Huske.app;
`spareSlotCount`, `replenishQuietPeriod` and `replenishSparesIfQuiet()` expose
the spare slots.
`@_spi(Testing) SyncServer.listenerEpoch` counts listener replacements (a call
that leaves it unchanged left the Bonjour advert alone), and
`SyncServer.hashFile` (internal) is the SHA-256 pass `commit` runs, so a test
can hold a verification open.

`@_spi(Testing) SyncServer.simulateListenerState(_:)` delivers a
`NWListener.State` to the live listener's handler (e.g. `.failed` to exercise
the restart path); `MacPresenceMonitor.deliverBrowserState(_:)` (internal) does
the same for the presence browser. `MacPresenceMonitor.deliverSighting(_:routes:)`
(internal) scripts where the Mac is seen (real browse results are ignored from
then on), and `FramedConnection.deliverState(_:)` (internal) delivers a
`NWConnection.State` to a connection that is still connecting.
