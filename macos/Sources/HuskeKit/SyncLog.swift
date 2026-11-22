// A small trail of what phone sync did, for "why isn't it syncing": listener
// state, phones connecting, uploads by ID and size, hand-offs to the engine,
// errors. One line per event with a timestamp. Never audio, recording titles
// or transcript text — callers pass plain status lines and this file is the
// only place they are written.
//
// Capped: when `sync.log` passes `maxBytes` it becomes `sync.log.1` (replacing
// the previous one) and a new file starts, so the two together stay under
// 2 × `maxBytes`. Writes are queued off the caller's thread.

import Foundation

public final class SyncLog: @unchecked Sendable {
    /// Per file; with the one rotated file, at most twice this on disk.
    public static let defaultMaxBytes = 200 * 1024
    /// A single line is cut here, so one runaway message cannot fill the file.
    static let maxLineLength = 600

    public let fileURL: URL
    public var previousURL: URL { fileURL.appendingPathExtension("1") }

    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "huske.sync.log", qos: .utility)
    /// Size of `fileURL`; nil until first measured. Queue-confined.
    private var size: Int?

    public init(
        fileURL: URL, maxBytes: Int = SyncLog.defaultMaxBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.maxBytes = max(1024, maxBytes)
        self.now = now
    }

    /// Appends one line. Returns at once; the write happens on a queue.
    public func write(_ message: String) {
        let stamp = now()
        queue.async { self.append(Self.line(message, at: stamp)) }
    }

    /// Waits until everything written so far is on disk.
    public func flush() {
        queue.sync {}
    }

    /// The most recent lines, oldest first: the end of the previous file and
    /// the current one, cut to `maxBytes` at a line boundary.
    public func tail(maxBytes limit: Int = 48 * 1024) -> String {
        queue.sync {
            var data = (try? Data(contentsOf: previousURL)) ?? Data()
            data.append((try? Data(contentsOf: fileURL)) ?? Data())
            guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
            var cut = data.suffix(limit)
            // Drop the first, partial line.
            if let newline = cut.firstIndex(of: UInt8(ascii: "\n")) {
                cut = cut[cut.index(after: newline)...]
            }
            return String(decoding: cut, as: UTF8.self)
        }
    }

    // MARK: formatting

    static func line(_ message: String, at date: Date, timeZone: TimeZone = .current) -> String {
        var text = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if text.count > maxLineLength {
            text = String(text.prefix(maxLineLength)) + "…"
        }
        return "\(timestamp(date, timeZone: timeZone)) \(text)\n"
    }

    /// `2026-11-19T14:03:00-03:00` — local time with its offset.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    // MARK: writing (queue-confined)

    private func append(_ line: String) {
        let data = Data(line.utf8)
        let fm = FileManager.default
        if size == nil {
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            size = ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue
        }
        if let current = size, current > 0, current + data.count > maxBytes {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: fileURL, to: previousURL)
            size = nil
        }
        if !fm.fileExists(atPath: fileURL.path) {
            // Private like everything else under PhoneSync.
            guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { return }
            size = 0
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            size = (size ?? 0) + data.count
        } catch {
            // A log that cannot be written must never get in sync's way.
            size = nil
        }
    }
}
