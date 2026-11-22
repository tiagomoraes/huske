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
    public static let protocolVersion = 1
    public static let urlScheme = "huske"
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
    public init(invite: PairingInvite, pairedAt: Date = .now)
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
}

public struct Welcome: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let macID: String
    public let macName: String
    public let serverVersion: String
    public let engineAvailable: Bool
}

public enum SyncError: Error, Sendable, Equatable {
    case macNotFound          // Bonjour did not find the paired Mac in time
    case handshakeFailed(String)  // TLS/PSK failure (e.g. unpaired on the Mac)
    case connectionClosed
    case protocolError(code: String, message: String)
    case checksumMismatch
    case timeout
    case io(String)
}

// MARK: - iPhone side

/// Watches Bonjour for one paired Mac. `isReachable` drives the UI dot and
/// triggers uploads.
public final class MacPresenceMonitor: @unchecked Sendable {
    public init(macID: String)
    public func start()
    public func stop()
    /// Emits whenever reachability changes (current value first).
    public var updates: AsyncStream<Bool> { get }
    public var isReachable: Bool { get }
}

public final class SyncClient: Sendable {
    public init(pairing: PairedMac, deviceName: String, deviceModel: String, appVersion: String)
    /// Browse for the paired Mac (≤ `timeout`), connect with TLS-PSK, send hello.
    public func connect(timeout: TimeInterval = 8) async throws -> SyncSession
}

public final class SyncSession: Sendable {
    public var welcome: Welcome { get }
    /// Offer → (resume from offset | skip) → chunks → commit.
    /// `progress(sent, total)` is called on an arbitrary queue.
    public func upload(manifest: RecordingManifest, fileURL: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus
    public func status(_ recordingIDs: [String]) async throws -> [RemoteStatus]
    public func transcript(_ recordingID: String) async throws -> String?
    public func close() async
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
}

public final class SyncServer: @unchecked Sendable {
    public init(registry: DeviceRegistry, stagingDirectory: URL, macName: String,
                serverVersion: String, port: UInt16 = 0)  // 0 = ephemeral
    public weak var delegate: SyncServerDelegate?
    public func start() throws
    public func stop()
    public var isRunning: Bool { get }
    public var port: UInt16? { get }
    /// Mint + register a pending invite (restarts the listener with the new key).
    public func makeInvite() -> PairingInvite
    /// Forget a device (restarts the listener without its key).
    public func removeDevice(_ deviceID: String)
}
```

## Test hooks

`SyncClient` must be usable in `swift test` against a `SyncServer` in the same
process over loopback/Bonjour. If Bonjour is unreliable in CI, an internal or
`@_spi(Testing)` initializer may connect to an explicit `NWEndpoint` (host +
port) instead.
