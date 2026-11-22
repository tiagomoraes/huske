// Shared models of the phone ↔ Mac sync protocol (v1). The wire contract is
// specs/002-phone-sync/contracts/sync-protocol.md; the Swift API contract the
// iPhone app codes against is specs/002-phone-sync/contracts/huskesync-api.md.
// Every public signature listed there must stay; additions are fine.

import CryptoKit
import Foundation

// MARK: - constants

public enum SyncConstants {
    public static let serviceType = "_huske-sync._tcp"
    public static let protocolVersion = 1
    public static let urlScheme = "huske"

    /// How long a pairing invite (QR code) stays valid.
    public static let inviteLifetime: TimeInterval = 10 * 60
    /// Recommended upload body size.
    public static let chunkSize = 256 * 1024
    /// Framing limits (sync-protocol.md § Framing).
    public static let maxHeaderLength = 65_536
    public static let maxBodyLength = 1_048_576
    /// RecordingManifest.byteCount ceiling (4 GiB).
    public static let maxRecordingBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// Audio containers a recording may arrive in. A closed list keeps a
    /// paired client from picking names that collide with our own sidecars
    /// (`<id>.json`, `<id>.manifest.json`).
    public static let audioExtensions: Set<String> = [
        "m4a", "aac", "caf", "wav", "aif", "aiff", "mp3", "flac", "ogg", "opus",
    ]

    /// `^[A-Za-z0-9._-]{1,64}$` — recording and device IDs.
    /// A leading "." is refused too (no ".", "..", or hidden names), matching
    /// the engine inbox's ID rule.
    public static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count), id.first != "." else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"),
                UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - pairing

/// What the QR code / pairing link carries. Minted by the Mac.
public struct PairingInvite: Codable, Sendable, Equatable {
    public let macID: String
    public let macName: String
    /// PSK identity for this phone.
    public let deviceID: String
    /// 32-byte PSK.
    public let key: Data
    public let expiresAt: Date

    public init(macID: String, macName: String, deviceID: String, key: Data, expiresAt: Date) {
        self.macID = macID
        self.macName = macName
        self.deviceID = deviceID
        self.key = key
        self.expiresAt = expiresAt
    }

    /// Mint a fresh invite (random deviceID + 32-byte key, 10-minute expiry).
    public static func mint(macID: String, macName: String, now: Date = .now) -> PairingInvite {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return PairingInvite(
            macID: macID,
            macName: macName,
            deviceID: UUID().uuidString,
            key: key,
            expiresAt: now.addingTimeInterval(SyncConstants.inviteLifetime))
    }

    public func isExpired(now: Date = .now) -> Bool { expiresAt <= now }

    /// `huske://pair?v=1&mac=…&name=…&id=…&exp=…&key=…`
    public var url: URL {
        let items: [(String, String)] = [
            ("v", String(SyncConstants.protocolVersion)),
            ("mac", macID),
            ("name", macName),
            ("id", deviceID),
            ("exp", String(Int(expiresAt.timeIntervalSince1970))),
            // Last on purpose: a link cut short loses key bytes and is
            // rejected, rather than parsing with a mangled expiry.
            ("key", Base64URL.encode(key)),
        ]
        let query = items
            .map { "\($0.0)=\(Self.strictPercentEncode($0.1))" }
            .joined(separator: "&")
        // Every component is strictly encoded above, so this cannot fail.
        return URL(string: "\(SyncConstants.urlScheme)://pair?\(query)")!
    }

    /// Parses a pairing URL (also accepts the URL embedded in surrounding text).
    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    public init?(string: String) {
        guard let candidate = Self.extractURLString(from: string),
            let components = URLComponents(string: candidate),
            components.scheme?.lowercased() == SyncConstants.urlScheme,
            components.host?.lowercased() == "pair"
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        guard values["v"] == String(SyncConstants.protocolVersion),
            let mac = values["mac"], !mac.isEmpty,
            let deviceID = values["id"], SyncConstants.isValidID(deviceID),
            let keyText = values["key"],
            let key = Base64URL.decode(keyText), key.count == 32
        else { return nil }
        // `exp` (Unix seconds) lets the phone say "expired" up front; the Mac
        // enforces it regardless. Links without it get the nominal window.
        let expiresAt = values["exp"].flatMap(Int.init).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? Date().addingTimeInterval(SyncConstants.inviteLifetime)
        self.init(
            macID: mac,
            macName: values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Mac",
            deviceID: deviceID,
            key: key,
            expiresAt: expiresAt)
    }

    /// Finds `huske://pair?…` in arbitrary text (a pasted message, a note).
    static func extractURLString(from text: String) -> String? {
        let lower = text.lowercased()
        guard let start = lower.range(of: "\(SyncConstants.urlScheme)://pair") else { return nil }
        let tail = text[start.lowerBound...]
        let stop = tail.firstIndex { ch in
            ch.isWhitespace || "\"'<>()[]{}`".contains(ch)
        }
        return String(tail[..<(stop ?? tail.endIndex)])
    }

    private static let strictAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func strictPercentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? value
    }
}

/// The iPhone's record of the Mac it is paired with (stored in the Keychain).
public struct PairedMac: Codable, Sendable, Equatable {
    public let macID: String
    public var macName: String
    public let deviceID: String
    public let key: Data
    public let pairedAt: Date

    public init(invite: PairingInvite, pairedAt: Date = .now) {
        self.macID = invite.macID
        self.macName = invite.macName
        self.deviceID = invite.deviceID
        self.key = invite.key
        self.pairedAt = pairedAt
    }

    public init(macID: String, macName: String, deviceID: String, key: Data, pairedAt: Date) {
        self.macID = macID
        self.macName = macName
        self.deviceID = deviceID
        self.key = key
        self.pairedAt = pairedAt
    }
}

// MARK: - recordings

public struct RecordingManifest: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public let startedAt: Date
    public var durationSeconds: Double
    public let byteCount: Int64
    /// lowercase hex
    public let sha256: String
    /// "m4a"
    public let fileExtension: String
    /// "audio/mp4"
    public let contentType: String
    public let sampleRate: Double
    public let channels: Int
    /// IANA identifier
    public let timeZone: String
    public let deviceName: String

    public init(
        id: String,
        title: String,
        startedAt: Date,
        durationSeconds: Double,
        byteCount: Int64,
        sha256: String,
        fileExtension: String,
        contentType: String,
        sampleRate: Double,
        channels: Int,
        timeZone: String,
        deviceName: String
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.sha256 = sha256
        self.fileExtension = fileExtension
        self.contentType = contentType
        self.sampleRate = sampleRate
        self.channels = channels
        self.timeZone = timeZone
        self.deviceName = deviceName
    }

    /// Hashes the file (streaming) and fills byteCount + sha256.
    public static func make(
        id: String, title: String, startedAt: Date,
        durationSeconds: Double, fileURL: URL, sampleRate: Double,
        channels: Int, timeZone: TimeZone, deviceName: String
    ) throws -> RecordingManifest {
        let (count, digest) = try FileHashing.sha256(of: fileURL)
        let ext = fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension.lowercased()
        return RecordingManifest(
            id: id,
            title: title,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            byteCount: count,
            sha256: digest,
            fileExtension: ext,
            contentType: Self.contentType(forExtension: ext),
            sampleRate: sampleRate,
            channels: channels,
            timeZone: timeZone.identifier,
            deviceName: deviceName)
    }

    public static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "aif", "aiff": return "audio/aiff"
        case "ogg", "opus": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    /// Wire-level validation the server applies to an `offer`.
    func validationError() -> String? {
        if !SyncConstants.isValidID(id) { return "recording id must match ^[A-Za-z0-9._-]{1,64}$" }
        if byteCount < 0 || byteCount > SyncConstants.maxRecordingBytes {
            return "byteCount must be between 0 and 4 GiB"
        }
        if sha256.count != 64 || !sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return "sha256 must be 64 lowercase hex characters"
        }
        if !SyncConstants.audioExtensions.contains(fileExtension) {
            return "fileExtension must be one of \(SyncConstants.audioExtensions.sorted().joined(separator: ", "))"
        }
        return nil
    }
}

public enum RemoteState: String, Codable, Sendable {
    case unknown, receiving, received, queued, transcribing, transcribed, failed

    /// `transcribed || failed`
    public var isTerminal: Bool { self == .transcribed || self == .failed }

    /// Tolerates states added by a newer Mac: they decode as `.unknown`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteState(rawValue: raw) ?? .unknown
    }
}

public struct RemoteStatus: Codable, Sendable, Equatable {
    public let recordingID: String
    public let state: RemoteState
    public let detail: String?
    public let updatedAt: Date
    public let progress: Double?

    public init(
        recordingID: String, state: RemoteState, detail: String? = nil,
        updatedAt: Date = .now, progress: Double? = nil
    ) {
        self.recordingID = recordingID
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
        self.progress = progress
    }

    public static func unknown(_ recordingID: String, now: Date = .now) -> RemoteStatus {
        RemoteStatus(recordingID: recordingID, state: .unknown, updatedAt: now)
    }
}

public struct Welcome: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let macID: String
    public let macName: String
    public let serverVersion: String
    public let engineAvailable: Bool

    public init(
        protocolVersion: Int, macID: String, macName: String,
        serverVersion: String, engineAvailable: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.macID = macID
        self.macName = macName
        self.serverVersion = serverVersion
        self.engineAvailable = engineAvailable
    }
}

public enum SyncError: Error, Sendable, Equatable {
    /// Bonjour did not find the paired Mac in time.
    case macNotFound
    /// TLS/PSK failure (e.g. unpaired on the Mac).
    case handshakeFailed(String)
    case connectionClosed
    case protocolError(code: String, message: String)
    case checksumMismatch
    case timeout
    case io(String)
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .macNotFound: return "The paired Mac was not found nearby."
        case .handshakeFailed(let why): return "The Mac refused the connection (\(why))."
        case .connectionClosed: return "The connection to the Mac closed."
        case .protocolError(let code, let message): return "\(code): \(message)"
        case .checksumMismatch: return "The upload was corrupted in transit and will restart."
        case .timeout: return "The Mac did not answer in time."
        case .io(let why): return why
        }
    }
}

// MARK: - Mac side models

/// One phone known to the Mac (pending or paired).
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let key: Data
    /// from hello
    public var name: String?
    public var model: String?
    public let createdAt: Date
    /// nil = pending invite
    public var pairedAt: Date?
    public var lastSeenAt: Date?
    /// pending only
    public var expiresAt: Date?

    public var isPaired: Bool { pairedAt != nil }

    public init(
        deviceID: String, key: Data, name: String? = nil, model: String? = nil,
        createdAt: Date = .now, pairedAt: Date? = nil, lastSeenAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.key = key
        self.name = name
        self.model = model
        self.createdAt = createdAt
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
    }

    /// A pending slot past its expiry. Paired devices never expire.
    public func isExpired(now: Date = .now) -> Bool {
        guard !isPaired, let expiresAt else { return false }
        return expiresAt <= now
    }
}

// MARK: - helpers

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

enum FileHashing {
    /// Streams the file through SHA-256 in 1 MiB reads.
    static func sha256(of url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let data = try autoreleasepoolCompat { try handle.read(upToCount: 1 << 20) }
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
            total += Int64(data.count)
        }
        return (total, hasher.finalize().hexString)
    }

    @inline(__always)
    static func autoreleasepoolCompat<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
            return try autoreleasepool(invoking: body)
        #else
            return try body()
        #endif
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
