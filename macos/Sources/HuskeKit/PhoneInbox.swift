// The app's side of the engine inbox contract
// (specs/002-phone-sync/contracts/inbox.md): build `huske inbox add`
// arguments for a received phone recording, read the engine-owned
// `<inbox_root>/<id>/status.json` (a documented read-only contract, so the
// app can poll without spawning a process), map it onto the sync protocol's
// RemoteStatus, and assemble the transcript the phone gets back.
//
// Pure where possible so HuskeKitTests can pin it; the Huske target's
// PhoneSyncCoordinator does the I/O orchestration.

import Foundation
import HuskeSync

/// One inbox item as `status.json` (or `huske inbox add/status --json`, which
/// merges `recording.json` fields into the same object) describes it.
public struct InboxItemStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case queued, processing, done, failed
    }

    public var id: String
    /// Raw engine state; unknown future states keep their text here.
    public var rawState: String
    public var updatedAt: Date?
    public var attempts: Int
    public var chunksTotal: Int
    public var chunksDone: Int
    /// How far the piece being transcribed has got (0…0.99), when the engine
    /// can estimate it (`chunk_progress`, inbox.md). nil = not known.
    public var chunkProgress: Double?
    public var sessionID: String?
    public var transcripts: [String]
    /// On a `failed` item that was split: the parts (1…N) that have no
    /// result (`missing_chunks`, inbox.md). `transcripts` then lists what the
    /// other parts produced.
    public var missingChunks: [Int]
    public var error: String?
    /// recording.json fields, present in CLI output.
    public var title: String?
    public var device: String?

    public var state: State? { State(rawValue: rawState) }

    public init(
        id: String, rawState: String, updatedAt: Date? = nil, attempts: Int = 0,
        chunksTotal: Int = 0, chunksDone: Int = 0, sessionID: String? = nil,
        transcripts: [String] = [], error: String? = nil, title: String? = nil,
        device: String? = nil, chunkProgress: Double? = nil, missingChunks: [Int] = []
    ) {
        self.id = id
        self.rawState = rawState
        self.updatedAt = updatedAt
        self.attempts = attempts
        self.chunksTotal = chunksTotal
        self.chunksDone = chunksDone
        self.chunkProgress = chunkProgress
        self.sessionID = sessionID
        self.transcripts = transcripts
        self.missingChunks = missingChunks
        self.error = error
        self.title = title
        self.device = device
    }
}

public enum PhoneInbox {
    /// `failed` items are retried by the engine until `attempts` reaches this.
    public static let maxAttempts = 3

    // MARK: locations

    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("huske/inbox", isDirectory: true)
    }

    /// `inbox_root` from `huske config show --json`, `~`-expanded.
    public static func root(fromConfigValue value: String?) -> URL {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultRoot()
        }
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public static func statusURL(root: URL, id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("status.json")
    }

    // MARK: reading status

    /// Audio an interrupted `huske inbox add` left in the engine's staging
    /// area (`<root>/.staging/<id>.<random>/audio.<ext>`), if any.
    public static func stagedAudio(root: URL, id: String) -> URL? {
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: staging.path) else { return nil }
        for dir in dirs where dir.hasPrefix("\(id).") {
            let folder = staging.appendingPathComponent(dir, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            if let audio = files.first(where: { $0.hasPrefix("audio.") }) {
                return folder.appendingPathComponent(audio)
            }
        }
        return nil
    }

    public static func readStatus(root: URL, id: String) -> InboxItemStatus? {
        guard SyncConstants.isValidID(id),
            let data = try? Data(contentsOf: statusURL(root: root, id: id))
        else { return nil }
        return parseStatus(data)
    }

    public static func parseStatus(_ data: Data) -> InboxItemStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseStatus(object)
    }

    static func parseStatus(_ object: [String: Any]) -> InboxItemStatus? {
        guard let id = object["id"] as? String, let state = object["state"] as? String else {
            return nil
        }
        func int(_ key: String) -> Int {
            (object[key] as? NSNumber)?.intValue ?? 0
        }
        func string(_ key: String) -> String? {
            guard let text = object[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        /// A number strictly inside 0…1; a JSON `true` is not one.
        func fraction(_ key: String) -> Double? {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            let value = number.doubleValue
            return value > 0 && value < 1 ? value : nil
        }
        return InboxItemStatus(
            id: id,
            rawState: state,
            updatedAt: string("updated_at").flatMap(parseDate),
            attempts: int("attempts"),
            chunksTotal: int("chunks_total"),
            chunksDone: int("chunks_done"),
            sessionID: string("session_id"),
            transcripts: (object["transcripts"] as? [Any])?.compactMap { $0 as? String } ?? [],
            error: string("error"),
            title: string("title"),
            device: string("device"),
            chunkProgress: fraction("chunk_progress"),
            missingChunks: (object["missing_chunks"] as? [Any])?.compactMap { entry in
                guard let number = entry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
                else { return nil }
                return number.intValue > 0 ? number.intValue : nil
            } ?? [])
    }

    /// Python's `isoformat(timespec="seconds")`, with or without an offset.
    public static func parseDate(_ text: String) -> Date? {
        if let date = WireDate.parse(text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    // MARK: mapping

    /// Engine inbox state → what the phone (and the iPhone pane) shows.
    ///
    /// A `failed` item with attempts left is reported as `queued`: the engine
    /// will retry it, and `failed` is terminal on the phone — it would stop
    /// asking and never fetch the transcript a retry produces.
    ///
    /// The status carries every optional extra (`retrying`, `partial`…); the
    /// sync server holds back the ones a phone did not announce, so `state`
    /// and `detail` must stay what an older phone expects.
    public static func remoteStatus(for item: InboxItemStatus, now: Date = .now) -> RemoteStatus {
        let updated = item.updatedAt ?? now
        switch item.state {
        case .queued:
            return RemoteStatus(
                recordingID: item.id, state: .queued,
                detail: "Waiting for the transcriber", updatedAt: updated)
        case .processing:
            // Whole parts done, plus the engine's estimate of the part in
            // flight: a long part used to sit on "1 of 3" for minutes and
            // look stuck.
            let within = item.chunksDone < item.chunksTotal ? (item.chunkProgress ?? 0) : 0
            let progress: Double? =
                item.chunksTotal > 0
                ? min(1, max(0, (Double(item.chunksDone) + within) / Double(item.chunksTotal))) : nil
            let detail =
                item.chunksTotal > 0
                ? "Transcribing part \(min(item.chunksDone + 1, item.chunksTotal)) of \(item.chunksTotal)"
                : "Transcribing"
            return RemoteStatus(
                recordingID: item.id, state: .transcribing, detail: detail, updatedAt: updated,
                progress: progress)
        case .done:
            let count = item.transcripts.count
            let detail: String
            switch count {
            case 0: detail = "No speech found"
            case 1: detail = "1 transcript chunk"
            default: detail = "\(count) transcript chunks"
            }
            return RemoteStatus(
                recordingID: item.id, state: .transcribed, detail: detail, updatedAt: updated,
                progress: 1)
        case .failed:
            let why = item.error ?? "Transcription failed"
            if item.attempts < maxAttempts {
                // The text is how phones without `status.retry` recognise
                // this state; do not reword it.
                return RemoteStatus(
                    recordingID: item.id, state: .queued,
                    detail: "\(engineRetryPrefix)\(why)", updatedAt: updated
                ).withRetry(attempt: item.attempts + 1, maxAttempts: maxAttempts)
            }
            let failed = RemoteStatus(recordingID: item.id, state: .failed, detail: why, updatedAt: updated)
            return hasPartialTranscript(item)
                ? failed.withPartialTranscript(done: item.chunksDone, total: item.chunksTotal) : failed
        case nil:
            return RemoteStatus(
                recordingID: item.id, state: .queued, detail: item.rawState, updatedAt: updated)
        }
    }

    /// `detail` of a failed item the engine will retry, before the reason.
    public static let engineRetryPrefix = "Will retry after an error: "

    /// True for a failed item the engine will still retry.
    public static func isRetryable(_ item: InboxItemStatus) -> Bool {
        item.state == .failed && item.attempts < maxAttempts
    }

    /// True for an item the engine gave up on with some of its parts
    /// transcribed: there is something to read, marked as incomplete.
    public static func hasPartialTranscript(_ item: InboxItemStatus) -> Bool {
        item.state == .failed && item.attempts >= maxAttempts
            && !item.missingChunks.isEmpty && !item.transcripts.isEmpty
    }

    // MARK: hand-off

    /// `huske inbox add FILE --move --id … --json` for a verified upload.
    public static func addArguments(fileURL: URL, manifest: RecordingManifest) -> [String] {
        var args = [
            "inbox", "add", fileURL.path,
            "--move",
            "--id", manifest.id,
            "--origin", "phone",
        ]
        let title = manifest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { args += ["--title", title] }
        let device = manifest.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !device.isEmpty { args += ["--device", device] }
        let zone = TimeZone(identifier: manifest.timeZone) ?? .current
        args += ["--started-at", WireDate.format(manifest.startedAt, timeZone: zone)]
        if manifest.durationSeconds.isFinite, manifest.durationSeconds > 0 {
            args += ["--duration", String(format: "%.3f", manifest.durationSeconds)]
        }
        args.append("--json")
        return args
    }

    public enum AddOutcome: Equatable, Sendable {
        case added(InboxItemStatus, created: Bool)
        case failed(String)
    }

    /// Interprets `huske inbox add --json`: one JSON object on stdout, which
    /// the engine pretty-prints across several lines.
    public static func parseAddOutput(status: Int32, stdout: String, stderr: String) -> AddOutcome {
        if let object = jsonObject(in: stdout) {
            if let error = object["error"] as? String {
                return .failed(error)
            }
            if status == 0, let item = parseStatus(object) {
                return .added(item, created: (object["created"] as? Bool) ?? true)
            }
        }
        let message = (stderr + "\n" + stdout)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .failed(message ?? "huske inbox add exited with status \(status)")
    }

    // MARK: retry

    /// `huske inbox retry ID --json`: re-queue a `failed` item with a fresh
    /// attempt budget. The only way back from `failed`, which the phone treats
    /// as terminal ("retried on the Mac", sync-protocol.md).
    public static func retryArguments(id: String) -> [String] {
        ["inbox", "retry", id, "--json"]
    }

    public enum RetryOutcome: Equatable, Sendable {
        /// Back in the queue (`state` is `queued`).
        case retried(InboxItemStatus)
        /// The engine would not (unknown id, not failed, audio gone) or could
        /// not run; the text says why.
        case refused(String)
    }

    /// Interprets `huske inbox retry ID --json`:
    /// `{"items": [{…item…, "retried": bool, "error"?: "…"}]}`, or
    /// `{"error": "…"}` on a validation failure.
    public static func parseRetryOutput(
        id: String, status: Int32, stdout: String, stderr: String
    ) -> RetryOutcome {
        if let object = jsonObject(in: stdout) {
            if let error = object["error"] as? String {
                return .refused(error)
            }
            let items = (object["items"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            if let record = items.first(where: { ($0["id"] as? String) == id }) ?? items.first {
                if (record["retried"] as? Bool) == true, let item = parseStatus(record) {
                    return .retried(item)
                }
                if let error = record["error"] as? String, !error.isEmpty {
                    return .refused(error)
                }
                let state = record["state"] as? String ?? "unknown"
                if state == "unknown" {
                    return .refused("The engine no longer has this recording")
                }
                return .refused("Not failed (\(state))")
            }
        }
        let message = (stderr + "\n" + stdout)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .refused(message ?? "huske inbox retry exited with status \(status)")
    }

    /// The JSON object in `text`: the whole text, else the span from the
    /// first `{` to the last `}` (tolerates stray lines around it).
    static func jsonObject(in text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            return object
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
            start < end
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed[start...end].utf8)) as? [String: Any]
    }

    // MARK: transcripts

    /// Drops a leading YAML frontmatter block (`---` … `---`).
    public static func stripFrontmatter(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let afterOpen = normalized.index(normalized.startIndex, offsetBy: 4)
        let rest = normalized[afterOpen...]
        if let close = rest.range(of: "\n---\n") {
            return String(rest[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if rest.hasSuffix("\n---") || rest == "---" {
            return ""
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All transcript chunks of a recording, frontmatter stripped, in order.
    /// nil when none of the files can be read.
    public static func joinedTranscript(
        paths: [String], read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        if paths.isEmpty { return "" }
        let bodies = paths.compactMap(read).map(stripFrontmatter)
        guard !bodies.isEmpty else { return nil }
        return bodies.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The transcript for a finished item; nil while it is not done.
    public static func transcript(for item: InboxItemStatus) -> String? {
        guard item.state == .done else { return nil }
        return joinedTranscript(paths: item.transcripts)
    }

    /// The parts that were transcribed of an item the engine gave up on, in
    /// order; nil when it is not such an item or nothing of it can be read.
    /// Never served as a whole transcript: the phone is told it is partial.
    public static func partialTranscript(
        for item: InboxItemStatus,
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        guard hasPartialTranscript(item),
            let text = joinedTranscript(paths: item.transcripts, read: read), !text.isEmpty
        else { return nil }
        return text
    }
}
