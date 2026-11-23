// Wire format (sync-protocol.md § Framing + § Messages):
//
//   UInt32 BE headerLen | headerLen bytes of JSON | header.bodyLength bytes
//
// The header is a JSON object with a `type` string, the message's fields, and
// an optional `bodyLength`. Only `chunk` (client) and `transcriptReply`
// (server) carry a body.

import Foundation

// MARK: - message payloads

struct HelloMessage: Codable, Sendable, Equatable {
    /// The highest protocol version the phone speaks (sync-protocol.md §
    /// Versioning); the Mac answers with the one the connection will use.
    var protocolVersion: Int
    var deviceID: String
    var deviceName: String
    var deviceModel: String
    var appVersion: String
    /// Additive features the phone supports. Absent on the wire = none.
    var capabilities: [String]
    /// Stable for one install of the iPhone app. Sent only with the pairing
    /// that install keeps, never while it tries a new code next to a pairing
    /// that works: the Mac drops the install's other entries when it sees it.
    var installID: String?

    init(
        protocolVersion: Int, deviceID: String, deviceName: String, deviceModel: String,
        appVersion: String, capabilities: [String] = [], installID: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.capabilities = capabilities
        self.installID = installID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        deviceModel = try container.decode(String.self, forKey: .deviceModel)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        // Anything that is not a usable ID is "none", not a refused hello.
        installID = (try? container.decodeIfPresent(String.self, forKey: .installID))
            .flatMap { $0 }.flatMap { SyncConstants.isValidID($0) ? $0 : nil }
    }
}

struct OfferMessage: Codable, Sendable, Equatable {
    var recording: RecordingManifest
}

enum OfferAction: String, Codable, Sendable {
    case send, skip
}

struct OfferReplyMessage: Codable, Sendable, Equatable {
    var recordingID: String
    var action: OfferAction
    var offset: Int64
}

struct ChunkMessage: Codable, Sendable, Equatable {
    var recordingID: String
    var offset: Int64
}

struct ChunkAckMessage: Codable, Sendable, Equatable {
    var recordingID: String
    var received: Int64
}

struct CommitMessage: Codable, Sendable, Equatable {
    var recordingID: String
}

struct CommittedMessage: Codable, Sendable, Equatable {
    var status: RemoteStatus
}

struct StatusRequestMessage: Codable, Sendable, Equatable {
    var recordingIDs: [String]
}

struct StatusReplyMessage: Codable, Sendable, Equatable {
    var items: [RemoteStatus]
}

struct TranscriptRequestMessage: Codable, Sendable, Equatable {
    var recordingID: String
}

struct TranscriptReplyMessage: Codable, Sendable, Equatable {
    var recordingID: String
    var available: Bool
    /// `transcript.partial`: the body is what could be transcribed of a
    /// recording the Mac gave up on. Absent on the wire = a whole transcript.
    var partial: Bool?
}

/// `rekey`: the phone asks for a credential to replace the one it paired
/// with. `publicKey` is an ephemeral X25519 key (base64url) the answer is
/// sealed to, so the new key is not readable by someone who holds the old one
/// and recorded the connection (TLS-PSK has no forward secrecy).
struct RekeyMessage: Codable, Sendable, Equatable {
    var publicKey: String
}

/// `rekeyed`: the new credential. `deviceID` is its PSK identity; `sealedKey`
/// is the 32-byte key, sealed (ChaCha20-Poly1305, base64url) under the key
/// both sides derive from the X25519 exchange.
struct RekeyedMessage: Codable, Sendable, Equatable {
    var deviceID: String
    var publicKey: String
    var sealedKey: String
}

struct ErrorMessage: Codable, Sendable, Equatable {
    var code: String
    var message: String
    var received: Int64?

    init(code: ErrorCode, message: String, received: Int64? = nil) {
        self.code = code.rawValue
        self.message = message
        self.received = received
    }
}

enum ErrorCode: String, Sendable {
    case versionMismatch = "version_mismatch"
    case notHello = "not_hello"
    case badRequest = "bad_request"
    case offsetMismatch = "offset_mismatch"
    case checksumMismatch = "checksum_mismatch"
    case tooLarge = "too_large"
    case unknownRecording = "unknown_recording"
    /// The request is fine but cannot be served right now (`rekey` with no
    /// spare slot left); ask again on a later connection.
    case unavailable = "unavailable"
    case `internal` = "internal"
}

/// One protocol message, request or response.
enum WireMessage: Sendable, Equatable {
    case hello(HelloMessage)
    case welcome(Welcome)
    case offer(OfferMessage)
    case offerReply(OfferReplyMessage)
    case chunk(ChunkMessage, body: Data)
    case chunkAck(ChunkAckMessage)
    case commit(CommitMessage)
    case committed(CommittedMessage)
    case status(StatusRequestMessage)
    case statusReply(StatusReplyMessage)
    case transcript(TranscriptRequestMessage)
    case transcriptReply(TranscriptReplyMessage, body: Data)
    case rekey(RekeyMessage)
    case rekeyed(RekeyedMessage)
    case unpair
    case unpaired
    case bye
    case error(ErrorMessage)

    var type: String {
        switch self {
        case .hello: return "hello"
        case .welcome: return "welcome"
        case .offer: return "offer"
        case .offerReply: return "offerReply"
        case .chunk: return "chunk"
        case .chunkAck: return "chunkAck"
        case .commit: return "commit"
        case .committed: return "committed"
        case .status: return "status"
        case .statusReply: return "statusReply"
        case .transcript: return "transcript"
        case .transcriptReply: return "transcriptReply"
        case .rekey: return "rekey"
        case .rekeyed: return "rekeyed"
        case .unpair: return "unpair"
        case .unpaired: return "unpaired"
        case .bye: return "bye"
        case .error: return "error"
        }
    }
}

// MARK: - JSON coding

enum WireJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(WireDate.format(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = WireDate.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }
}

/// ISO 8601 with a UTC offset (`2026-11-19T14:03:00-03:00`), whole seconds on
/// output; fractional seconds and `Z` are accepted on input.
public enum WireDate {
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

// MARK: - framing

struct Frame: Sendable, Equatable {
    /// Raw header JSON.
    var header: Data
    var body: Data
}

private struct HeaderPeek: Decodable {
    var type: String
    var bodyLength: Int?
}

/// Encodes header fields: the payload's own keys plus `type` and, when a body
/// follows, `bodyLength`.
private struct Envelope<Payload: Encodable>: Encodable {
    let type: String
    let bodyLength: Int?
    let payload: Payload?

    enum CodingKeys: String, CodingKey { case type, bodyLength }

    func encode(to encoder: Encoder) throws {
        try payload?.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(bodyLength, forKey: .bodyLength)
    }
}

private struct Empty: Encodable {}

enum WireCodec {
    /// Message → bytes on the wire.
    static func encode(_ message: WireMessage) throws -> Data {
        let encoder = WireJSON.encoder()
        func header<P: Encodable>(_ payload: P?, bodyLength: Int? = nil) throws -> Data {
            try encoder.encode(
                Envelope(type: message.type, bodyLength: bodyLength, payload: payload))
        }
        let headerData: Data
        var body = Data()
        switch message {
        case .hello(let m): headerData = try header(m)
        case .welcome(let m): headerData = try header(m)
        case .offer(let m): headerData = try header(m)
        case .offerReply(let m): headerData = try header(m)
        case .chunk(let m, let data):
            headerData = try header(m, bodyLength: data.count)
            body = data
        case .chunkAck(let m): headerData = try header(m)
        case .commit(let m): headerData = try header(m)
        case .committed(let m): headerData = try header(m)
        case .status(let m): headerData = try header(m)
        case .statusReply(let m): headerData = try header(m)
        case .transcript(let m): headerData = try header(m)
        case .transcriptReply(let m, let data):
            headerData = try header(m, bodyLength: data.count)
            body = data
        case .rekey(let m): headerData = try header(m)
        case .rekeyed(let m): headerData = try header(m)
        case .unpair, .unpaired, .bye: headerData = try header(Empty?.none)
        case .error(let m): headerData = try header(m)
        }
        guard headerData.count <= SyncConstants.maxHeaderLength else {
            throw SyncError.protocolError(code: ErrorCode.tooLarge.rawValue, message: "header too large")
        }
        guard body.count <= SyncConstants.maxBodyLength else {
            throw SyncError.protocolError(code: ErrorCode.tooLarge.rawValue, message: "body too large")
        }
        var out = Data(capacity: 4 + headerData.count + body.count)
        var length = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(body)
        return out
    }

    /// Frame → message. Unknown types and malformed headers are `bad_request`.
    static func decode(_ frame: Frame) throws -> WireMessage {
        let decoder = WireJSON.decoder()
        let peek: HeaderPeek
        do {
            peek = try decoder.decode(HeaderPeek.self, from: frame.header)
        } catch {
            throw SyncError.protocolError(code: ErrorCode.badRequest.rawValue, message: "header is not a JSON object with a type")
        }
        func payload<P: Decodable>(_: P.Type) throws -> P {
            do {
                return try decoder.decode(P.self, from: frame.header)
            } catch {
                throw SyncError.protocolError(
                    code: ErrorCode.badRequest.rawValue,
                    message: "malformed \(peek.type): \(Self.describe(error))")
            }
        }
        switch peek.type {
        case "hello": return .hello(try payload(HelloMessage.self))
        case "welcome": return .welcome(try payload(Welcome.self))
        case "offer": return .offer(try payload(OfferMessage.self))
        case "offerReply": return .offerReply(try payload(OfferReplyMessage.self))
        case "chunk": return .chunk(try payload(ChunkMessage.self), body: frame.body)
        case "chunkAck": return .chunkAck(try payload(ChunkAckMessage.self))
        case "commit": return .commit(try payload(CommitMessage.self))
        case "committed": return .committed(try payload(CommittedMessage.self))
        case "status": return .status(try payload(StatusRequestMessage.self))
        case "statusReply": return .statusReply(try payload(StatusReplyMessage.self))
        case "transcript": return .transcript(try payload(TranscriptRequestMessage.self))
        case "transcriptReply":
            return .transcriptReply(try payload(TranscriptReplyMessage.self), body: frame.body)
        case "rekey": return .rekey(try payload(RekeyMessage.self))
        case "rekeyed": return .rekeyed(try payload(RekeyedMessage.self))
        case "unpair": return .unpair
        case "unpaired": return .unpaired
        case "bye": return .bye
        case "error": return .error(try payload(ErrorMessage.self))
        default:
            throw SyncError.protocolError(
                code: ErrorCode.badRequest.rawValue, message: "unknown message type \(peek.type)")
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx),
            DecodingError.dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
        default: return String(describing: error)
        }
    }
}

/// Incremental frame parser: feed it whatever the transport delivered (any
/// split, including mid-length-prefix) and pull complete frames out.
struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var pendingHeader: Data?
    private var pendingBodyLength = 0

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or nil if more bytes are needed.
    mutating func nextFrame() throws -> Frame? {
        if pendingHeader == nil {
            guard buffer.count >= 4 else { return nil }
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, Int(length) <= SyncConstants.maxHeaderLength else {
                throw SyncError.protocolError(
                    code: ErrorCode.tooLarge.rawValue, message: "header length \(length) out of range")
            }
            guard buffer.count >= 4 + Int(length) else { return nil }
            let header = Data(buffer.dropFirst(4).prefix(Int(length)))
            buffer = Data(buffer.dropFirst(4 + Int(length)))
            let peek: HeaderPeek
            do {
                peek = try JSONDecoder().decode(HeaderPeek.self, from: header)
            } catch {
                throw SyncError.protocolError(
                    code: ErrorCode.badRequest.rawValue, message: "header is not a JSON object with a type")
            }
            let bodyLength = peek.bodyLength ?? 0
            guard bodyLength >= 0, bodyLength <= SyncConstants.maxBodyLength else {
                throw SyncError.protocolError(
                    code: ErrorCode.tooLarge.rawValue, message: "bodyLength \(bodyLength) out of range")
            }
            pendingHeader = header
            pendingBodyLength = bodyLength
        }
        guard let header = pendingHeader, buffer.count >= pendingBodyLength else { return nil }
        let body = Data(buffer.prefix(pendingBodyLength))
        buffer = Data(buffer.dropFirst(pendingBodyLength))
        pendingHeader = nil
        pendingBodyLength = 0
        return Frame(header: header, body: body)
    }
}
