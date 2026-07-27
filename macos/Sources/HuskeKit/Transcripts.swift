// Parsers for huske's on-disk transcript contract
// (specs/001-huske-recorder/contracts/transcript-format.md):
//   <output_root>/YYYY-MM-DD/HHMMSS_<sessionid8>_<seq>.md
// with YAML frontmatter and a body of `[HH:MM:SS · source]` runs.
//
// The frontmatter is a fixed, flat key/value block (plus one list key), so a
// contract-shaped parser beats a YAML dependency: zero third-party code, and
// it cannot be silently lenient about the contract.

import Foundation

public struct TranscriptMeta: Equatable, Sendable {
    public var sessionId: String = ""
    public var chunkSeq: Int = 0
    public var date: String = ""
    public var startTime: Date?
    public var endTime: Date?
    public var rawStartTime: String = ""
    public var durationSeconds: Int = 0
    public var durationActualSeconds: Double = 0
    public var gapSeconds: Double = 0
    public var audioSources: [String] = []
    public var model: String = ""
    public var language: String = ""
    public var incomplete: Bool = false
    public var huskeVersion: String = ""

    public init() {}
}

public struct TranscriptRun: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable {
        case mic
        case system
        case micEcho = "mic · echo"
        case unknown
    }

    public let index: Int
    public let time: String // "HH:MM:SS" head timestamp of the run
    public let source: Source
    public let text: String

    public var id: Int { index }

    public init(index: Int, time: String, source: Source, text: String) {
        self.index = index
        self.time = time
        self.source = source
        self.text = text
    }
}

public struct TranscriptDocument: Equatable, Sendable {
    public let meta: TranscriptMeta
    public let heading: String?
    public let runs: [TranscriptRun]
    public let rawBody: String
    /// True when the body is the legacy literal no-speech marker.
    public var isEmpty: Bool {
        guard runs.isEmpty else { return false }
        let content = rawBody.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") }
        return content == ["_(no speech detected)_"]
    }
}

public struct TranscriptFilenameInfo: Equatable, Sendable {
    public let timeString: String // "HH:MM:SS"
    public let sessionId8: String
    public let chunkSeq: Int
}

public enum TranscriptParser {
    // MARK: filename

    /// `091500_8a3f2c19_002.md` → time/session/seq. Tolerates the collision
    /// disambiguation suffix (`..._002_a1b2.md`).
    public static func parseFilename(_ name: String) -> TranscriptFilenameInfo? {
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        let parts = stem.split(separator: "_")
        guard parts.count >= 3 else { return nil }
        let hhmmss = parts[0]
        let sid = parts[1]
        let seq = parts[2]
        guard hhmmss.count == 6, hhmmss.allSatisfy(\.isNumber),
              sid.count == 8,
              let seqInt = Int(seq)
        else { return nil }
        let h = hhmmss.prefix(2)
        let m = hhmmss.dropFirst(2).prefix(2)
        let s = hhmmss.dropFirst(4).prefix(2)
        return TranscriptFilenameInfo(
            timeString: "\(h):\(m):\(s)",
            sessionId8: String(sid),
            chunkSeq: seqInt
        )
    }

    /// True for day folders like `2026-05-07`.
    public static func isDayFolder(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // MARK: full document

    public static func parse(_ text: String) -> TranscriptDocument? {
        guard let (frontmatter, body) = splitFrontmatter(text) else { return nil }
        let meta = parseFrontmatter(frontmatter)
        let (heading, runs) = parseBody(body)
        return TranscriptDocument(meta: meta, heading: heading, runs: runs, rawBody: body)
    }

    static func splitFrontmatter(_ text: String) -> (String, String)? {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for (i, line) in lines.enumerated().dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let front = lines[1..<i].joined(separator: "\n")
                let body = lines[(i + 1)...].joined(separator: "\n")
                return (front, body)
            }
        }
        return nil
    }

    static func parseFrontmatter(_ front: String) -> TranscriptMeta {
        var meta = TranscriptMeta()
        var pendingListKey: String?
        for rawLine in front.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("- "), let key = pendingListKey {
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if key == "audio_sources" { meta.audioSources.append(unquote(item)) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                pendingListKey = key
                continue
            }
            pendingListKey = nil
            apply(key: key, value: unquote(value), to: &meta)
        }
        return meta
    }

    private static func apply(key: String, value: String, to meta: inout TranscriptMeta) {
        switch key {
        case "session_id": meta.sessionId = value
        case "chunk_seq": meta.chunkSeq = Int(value) ?? 0
        case "date": meta.date = value
        case "start_time":
            meta.rawStartTime = value
            meta.startTime = ISO8601.parse(value)
        case "end_time": meta.endTime = ISO8601.parse(value)
        case "duration_seconds": meta.durationSeconds = Int(Double(value) ?? 0)
        case "duration_actual_seconds": meta.durationActualSeconds = Double(value) ?? 0
        case "gap_seconds": meta.gapSeconds = Double(value) ?? 0
        case "audio_sources":
            // Inline form: [microphone, system]
            if value.hasPrefix("["), value.hasSuffix("]") {
                meta.audioSources = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
            }
        case "model": meta.model = value
        case "language": meta.language = value
        case "incomplete": meta.incomplete = (value == "true")
        case "huske_version": meta.huskeVersion = value
        default: break
        }
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: body

    /// Body paragraphs look like `[09:30:00 · system] Olá, vamos começar.`
    /// Runs may wrap over multiple lines until the next `[` paragraph head or
    /// a blank line followed by a new head.
    static func parseBody(_ body: String) -> (heading: String?, runs: [TranscriptRun]) {
        var heading: String?
        var runs: [TranscriptRun] = []
        var currentHead: (time: String, source: TranscriptRun.Source)?
        var currentText: [String] = []

        func flush() {
            if let head = currentHead {
                let text = currentText.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    runs.append(
                        TranscriptRun(index: runs.count, time: head.time, source: head.source, text: text))
                }
            }
            currentHead = nil
            currentText = []
        }

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# "), heading == nil, currentHead == nil {
                heading = String(line.dropFirst(2))
                continue
            }
            if let (time, source, rest) = parseRunHead(line) {
                flush()
                currentHead = (time, source)
                currentText = rest.isEmpty ? [] : [rest]
                continue
            }
            if line.isEmpty { continue }
            if currentHead != nil {
                currentText.append(line)
            }
        }
        flush()
        return (heading, runs)
    }

    /// `[09:30:00 · system] text` → ("09:30:00", .system, "text")
    static func parseRunHead(_ line: String) -> (String, TranscriptRun.Source, String)? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]")
        else { return nil }
        let inside = line[line.index(after: line.startIndex)..<close]
        let parts = inside.components(separatedBy: " · ")
        guard let time = parts.first,
              time.count == 8,
              parts.count >= 2
        else { return nil }
        let sourceRaw = parts.dropFirst().joined(separator: " · ")
        let source: TranscriptRun.Source
        switch sourceRaw {
        case "mic": source = .mic
        case "system": source = .system
        case "mic · echo": source = .micEcho
        default: source = .unknown
        }
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (String(time), source, rest)
    }
}
