// A short, bounded log of what sync did and why, kept on the phone for
// support ("Copy details" on the Mac screen). It holds link changes, attempts,
// errors, sizes and timings — never audio, transcript text, recording titles,
// device or Mac names, or keys. Recordings appear as the first 8 characters
// of their ID.

import Foundation

@MainActor
final class SyncJournal {
    enum Topic: String, Codable {
        case link, network, run, connect, upload, transcript, retry, pairing
    }

    struct Entry: Codable, Equatable {
        let at: Date
        let topic: Topic
        let text: String
    }

    static let defaultCapacity = 200

    private(set) var entries: [Entry] = []

    private let fileURL: URL?
    private let capacity: Int
    private let now: () -> Date
    private let writer = DispatchQueue(label: "huske.sync.journal", qos: .utility)

    /// - Parameter fileURL: where the journal persists; nil keeps it in memory
    ///   only (demo mode, tests).
    init(fileURL: URL? = nil, capacity: Int = SyncJournal.defaultCapacity, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.capacity = max(capacity, 1)
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? Self.decoder.decode([Entry].self, from: data) {
            entries = Array(stored.suffix(self.capacity))
        }
    }

    /// Appends one line, dropping the oldest beyond the capacity. Callers pass
    /// facts about the link and the transfer only — see the file header.
    func record(_ topic: Topic, _ text: String) {
        entries.append(Entry(at: now(), topic: topic, text: text))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        persist()
    }

    /// Waits for pending writes (tests).
    func flush() {
        writer.sync {}
    }

    /// The journal as text to paste into a support message: `header` lines
    /// (versions, current state), then one line per entry, oldest first.
    func report(header: [String]) -> String {
        var lines = header
        lines.append("")
        lines.append(entries.isEmpty ? "No sync activity recorded yet." : "Sync journal (oldest first, UTC):")
        for entry in entries {
            let topic = entry.topic.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("\(Self.stamp(entry.at))  \(topic)  \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// "4E1C0A5B-0F7E-…" → "4E1C0A5B": enough to tell recordings apart.
    nonisolated static func shortID(_ recordingID: String) -> String {
        String(recordingID.prefix(8))
    }

    // MARK: persistence

    private func persist() {
        guard let fileURL else { return }
        let snapshot = entries
        writer.async {
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            // Readable after first unlock: background sync writes while locked.
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    nonisolated static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
