// Observable index of the transcripts folder. Scans are pure functions over
// the directory layout (testable); the store schedules them off the main
// thread and watches the root for changes.

import Foundation
import Observation

public struct TranscriptEntry: Equatable, Sendable, Identifiable, Hashable {
    public let url: URL
    public let filename: String
    public let timeString: String
    public let sessionId8: String
    public let chunkSeq: Int

    public var id: URL { url }

    public init(url: URL, filename: String, timeString: String, sessionId8: String, chunkSeq: Int) {
        self.url = url
        self.filename = filename
        self.timeString = timeString
        self.sessionId8 = sessionId8
        self.chunkSeq = chunkSeq
    }
}

public struct TranscriptDay: Equatable, Sendable, Identifiable {
    public let date: String // YYYY-MM-DD
    public let entries: [TranscriptEntry] // chronological

    public var id: String { date }

    public init(date: String, entries: [TranscriptEntry]) {
        self.date = date
        self.entries = entries
    }
}

public enum TranscriptScanner {
    /// Scan `<root>/YYYY-MM-DD/*.md` into days, newest day first.
    public static func scan(root: URL, fileManager: FileManager = .default) -> [TranscriptDay] {
        guard let dayNames = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var days: [TranscriptDay] = []
        for dayName in dayNames where TranscriptParser.isDayFolder(dayName) {
            let dayURL = root.appendingPathComponent(dayName, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(atPath: dayURL.path) else {
                continue
            }
            var entries: [TranscriptEntry] = []
            for file in files where file.hasSuffix(".md") {
                guard let info = TranscriptParser.parseFilename(file) else { continue }
                entries.append(
                    TranscriptEntry(
                        url: dayURL.appendingPathComponent(file),
                        filename: file,
                        timeString: info.timeString,
                        sessionId8: info.sessionId8,
                        chunkSeq: info.chunkSeq
                    ))
            }
            guard !entries.isEmpty else { continue }
            entries.sort { $0.filename < $1.filename } // lexicographic == chronological
            days.append(TranscriptDay(date: dayName, entries: entries))
        }
        days.sort { $0.date > $1.date }
        return days
    }
}

@MainActor
@Observable
public final class TranscriptStore {
    public private(set) var root: URL?
    public private(set) var days: [TranscriptDay] = []
    public private(set) var isScanning = false

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFD: Int32 = -1

    public init() {}

    public var totalCount: Int { days.reduce(0) { $0 + $1.entries.count } }

    /// Preview/render seam: set contents synchronously without scanning.
    public func _previewInject(root: URL?, days: [TranscriptDay]) {
        stopWatching()
        self.root = root
        self.days = days
    }

    public func setRoot(_ url: URL?) {
        guard url != root else { return }
        root = url
        days = []
        stopWatching()
        guard url != nil else { return }
        refresh()
        startWatching()
    }

    public func refresh() {
        guard let root else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = TranscriptScanner.scan(root: root)
            await MainActor.run { [weak self] in
                guard let self, self.root == root else { return }
                self.days = scanned
                self.isScanning = false
            }
        }
    }

    public func loadDocument(at url: URL) async -> TranscriptDocument? {
        let task = Task.detached(priority: .userInitiated) { () -> TranscriptDocument? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return TranscriptParser.parse(text)
        }
        return await task.value
    }

    /// Case-insensitive plain-text search across all transcript bodies.
    public func search(_ query: String) async -> [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let candidates = days.flatMap(\.entries)
        let task = Task.detached(priority: .userInitiated) { () -> [TranscriptEntry] in
            var hits: [TranscriptEntry] = []
            for entry in candidates {
                guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
                if text.lowercased().contains(needle) {
                    hits.append(entry)
                }
            }
            return hits
        }
        return await task.value
    }

    // MARK: directory watching

    private func startWatching() {
        guard let root else { return }
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
    }
}
