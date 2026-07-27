// Swift side of huske's JSON-line control protocol.
// Mirror of ../../huske/ipc/protocol.py — one JSON object per "\n"-terminated
// line. Snapshot fields added after v1 are optional on the wire; this decoder
// applies the same defaults as the Python dataclass so either side can be
// older than the other.

import Foundation

public enum ControlCommand: String, Sendable, CaseIterable {
    case pauseResume = "pause_resume"
    case toggleScreenshots = "toggle_screenshots"
    case toggleDistill = "toggle_distill"
    case stop = "stop"
    case openTranscripts = "open_transcripts"
    case openLatestTranscript = "open_latest_transcript"
    case setInputDevice = "set_input_device"
    case requestDevices = "request_devices"
}

public struct SessionEvent: Equatable, Sendable, Identifiable, Hashable {
    public let ts: Date?
    public let rawTimestamp: String
    public let severity: Severity
    public let message: String

    public enum Severity: String, Sendable {
        case info, warn, error
    }

    public var id: String { rawTimestamp + "|" + message }

    public init(rawTimestamp: String, severity: Severity, message: String) {
        self.rawTimestamp = rawTimestamp
        self.severity = severity
        self.message = message
        self.ts = ISO8601.parse(rawTimestamp)
    }
}

public struct ControlSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var recording: Bool
    public var paused: Bool
    public var stopping: Bool
    public var currentChunkSeq: Int
    public var queueDepth: Int
    public var screenshotsEnabled: Bool
    public var distillEnabled: Bool
    public var lastSavedName: String?
    // v2
    public var peakMicDb: Double
    public var peakSystemDb: Double
    public var chunkStartedAt: Date?
    public var nextRotationAt: Date?
    public var sessionStartedAt: Date?
    public var huskeVersion: String
    public var outputRoot: String?
    public var lastSavedPath: String?
    public var screenshotsCount: Int
    public var inputDeviceName: String?
    public var warnings: [String: String]
    public var events: [SessionEvent]

    public init(
        sessionId: String,
        recording: Bool,
        paused: Bool,
        stopping: Bool,
        currentChunkSeq: Int,
        queueDepth: Int,
        screenshotsEnabled: Bool,
        distillEnabled: Bool,
        lastSavedName: String? = nil,
        peakMicDb: Double = -120.0,
        peakSystemDb: Double = -120.0,
        chunkStartedAt: Date? = nil,
        nextRotationAt: Date? = nil,
        sessionStartedAt: Date? = nil,
        huskeVersion: String = "",
        outputRoot: String? = nil,
        lastSavedPath: String? = nil,
        screenshotsCount: Int = 0,
        inputDeviceName: String? = nil,
        warnings: [String: String] = [:],
        events: [SessionEvent] = []
    ) {
        self.sessionId = sessionId
        self.recording = recording
        self.paused = paused
        self.stopping = stopping
        self.currentChunkSeq = currentChunkSeq
        self.queueDepth = queueDepth
        self.screenshotsEnabled = screenshotsEnabled
        self.distillEnabled = distillEnabled
        self.lastSavedName = lastSavedName
        self.peakMicDb = peakMicDb
        self.peakSystemDb = peakSystemDb
        self.chunkStartedAt = chunkStartedAt
        self.nextRotationAt = nextRotationAt
        self.sessionStartedAt = sessionStartedAt
        self.huskeVersion = huskeVersion
        self.outputRoot = outputRoot
        self.lastSavedPath = lastSavedPath
        self.screenshotsCount = screenshotsCount
        self.inputDeviceName = inputDeviceName
        self.warnings = warnings
        self.events = events
    }
}

public struct InputDeviceEntry: Equatable, Sendable, Identifiable, Hashable {
    public let index: Int
    public let name: String
    public let channels: Int
    public let sampleRate: Double

    public var id: Int { index }

    public init(index: Int, name: String, channels: Int, sampleRate: Double) {
        self.index = index
        self.name = name
        self.channels = channels
        self.sampleRate = sampleRate
    }
}

public struct DeviceList: Equatable, Sendable {
    public let devices: [InputDeviceEntry]
    public let currentIndex: Int?

    public init(devices: [InputDeviceEntry], currentIndex: Int?) {
        self.devices = devices
        self.currentIndex = currentIndex
    }
}

public enum ControlMessage: Equatable, Sendable {
    case state(ControlSnapshot)
    case devices(DeviceList)
}

public enum ControlProtocolError: Error, Equatable {
    case notJSON
    case unknownType(String)
    case missingField(String)
}

public enum ControlProtocol {
    /// Decode one wire line into a message. Command lines are server-bound and
    /// never decoded here (the app is always the client).
    public static func decode(line: String) throws -> ControlMessage {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ControlProtocolError.notJSON
        }
        guard let type = obj["type"] as? String else {
            throw ControlProtocolError.missingField("type")
        }
        switch type {
        case "state":
            return .state(try decodeSnapshot(obj))
        case "devices":
            return .devices(decodeDevices(obj))
        default:
            throw ControlProtocolError.unknownType(type)
        }
    }

    /// Encode a command line for the server. `arg` may be a String or Int.
    public static func encodeCommand(_ command: ControlCommand, arg: (any Sendable)? = nil) -> Data {
        var payload: [String: Any] = ["type": "cmd", "name": command.rawValue]
        if let arg = arg as? String {
            payload["arg"] = arg
        } else if let arg = arg as? Int {
            payload["arg"] = arg
        }
        // Keys/values are plain strings and ints — serialization cannot fail.
        var data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func decodeSnapshot(_ obj: [String: Any]) throws -> ControlSnapshot {
        func require<T>(_ key: String) throws -> T {
            guard let value = obj[key] as? T else {
                throw ControlProtocolError.missingField(key)
            }
            return value
        }
        let rawEvents = obj["events"] as? [[String: Any]] ?? []
        let events: [SessionEvent] = rawEvents.compactMap { entry in
            guard let message = entry["message"] as? String else { return nil }
            let severity = SessionEvent.Severity(
                rawValue: entry["severity"] as? String ?? "info") ?? .info
            return SessionEvent(
                rawTimestamp: entry["ts"] as? String ?? "",
                severity: severity,
                message: message
            )
        }
        return ControlSnapshot(
            sessionId: try require("session_id"),
            recording: try require("recording"),
            paused: try require("paused"),
            stopping: try require("stopping"),
            currentChunkSeq: try require("current_chunk_seq"),
            queueDepth: try require("queue_depth"),
            screenshotsEnabled: try require("screenshots_enabled"),
            distillEnabled: try require("distill_enabled"),
            lastSavedName: obj["last_saved_name"] as? String,
            peakMicDb: doubleValue(obj["peak_mic_db"]) ?? -120.0,
            peakSystemDb: doubleValue(obj["peak_system_db"]) ?? -120.0,
            chunkStartedAt: (obj["chunk_started_at"] as? String).flatMap(ISO8601.parse),
            nextRotationAt: (obj["next_rotation_at"] as? String).flatMap(ISO8601.parse),
            sessionStartedAt: (obj["session_started_at"] as? String).flatMap(ISO8601.parse),
            huskeVersion: obj["huske_version"] as? String ?? "",
            outputRoot: obj["output_root"] as? String,
            lastSavedPath: obj["last_saved_path"] as? String,
            screenshotsCount: obj["screenshots_count"] as? Int ?? 0,
            inputDeviceName: obj["input_device_name"] as? String,
            warnings: obj["warnings"] as? [String: String] ?? [:],
            events: events
        )
    }

    private static func decodeDevices(_ obj: [String: Any]) -> DeviceList {
        let raw = obj["devices"] as? [[String: Any]] ?? []
        let devices: [InputDeviceEntry] = raw.compactMap { entry in
            guard let index = entry["index"] as? Int,
                  let name = entry["name"] as? String
            else { return nil }
            return InputDeviceEntry(
                index: index,
                name: name,
                channels: entry["channels"] as? Int ?? 1,
                sampleRate: doubleValue(entry["sample_rate"]) ?? 48000.0
            )
        }
        return DeviceList(devices: devices, currentIndex: obj["current_index"] as? Int)
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}

/// Tolerant ISO 8601 parsing. Python's `datetime.isoformat()` emits
/// microsecond fractions ("2026-07-21T09:15:32.123456-03:00"), which
/// `ISO8601DateFormatter` rejects (it only accepts milliseconds), so fractions
/// are truncated to 3 digits before parsing.
public enum ISO8601 {
    public static func parse(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let trimmed = truncateFraction(raw)
        if let date = fractional.date(from: trimmed) { return date }
        if let date = plain.date(from: trimmed) { return date }
        return nil
    }

    private static func truncateFraction(_ raw: String) -> String {
        guard let dotIndex = raw.firstIndex(of: ".") else { return raw }
        let afterDot = raw.index(after: dotIndex)
        var digitsEnd = afterDot
        while digitsEnd < raw.endIndex, raw[digitsEnd].isNumber {
            digitsEnd = raw.index(after: digitsEnd)
        }
        let digits = raw[afterDot..<digitsEnd]
        guard digits.count > 3 else { return raw }
        return String(raw[..<afterDot]) + digits.prefix(3) + String(raw[digitsEnd...])
    }

    // ISO8601DateFormatter is documented thread-safe; the annotation only
    // silences strict-concurrency checking for the shared instances.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
