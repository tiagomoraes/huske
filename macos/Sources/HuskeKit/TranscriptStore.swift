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
    public let entries: [TranscriptEntry] // newest first

    public var id: String { date }

    public init(date: String, entries: [TranscriptEntry]) {
        self.date = date
        self.entries = entries
    }
}

/// Memoized "is this a legacy no-speech marker?" verdicts, keyed by path and
/// invalidated by (size, mtime). Transcripts are written once and never
/// touched again, so a warm cache turns a rescan from "read and parse every
/// small file on disk" into "read the one chunk that just landed".
///
/// A value type on purpose: the scan runs off the main actor, so the store
/// hands it a snapshot and takes the updated copy back with the results.
public struct TranscriptScanCache: Sendable, Equatable {
    struct Verdict: Sendable, Equatable {
        let size: Int
        let mtime: Date
        let isMarker: Bool
    }

    var verdicts: [String: Verdict] = [:]

    public init() {}

    public var count: Int { verdicts.count }
}

public struct TranscriptScanResult: Sendable {
    public let days: [TranscriptDay]
    /// Rebuilt from the files actually seen, so deleted files drop out.
    public let cache: TranscriptScanCache
    /// Files whose marker verdict had to be read from disk this scan.
    public let filesRead: Int
}

public enum TranscriptScanner {
    /// Scan `<root>/YYYY-MM-DD/*.md` into days and entries, newest first.
    public static func scan(root: URL, fileManager: FileManager = .default) -> [TranscriptDay] {
        scan(root: root, cache: TranscriptScanCache(), fileManager: fileManager).days
    }

    /// Cache-aware scan. Pass the previous result's `cache` back in; unchanged
    /// files reuse their verdict instead of being reread and reparsed.
    public static func scan(
        root: URL,
        cache: TranscriptScanCache,
        fileManager: FileManager = .default
    ) -> TranscriptScanResult {
        guard let dayNames = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return TranscriptScanResult(days: [], cache: TranscriptScanCache(), filesRead: 0)
        }
        var days: [TranscriptDay] = []
        var fresh = TranscriptScanCache()
        var filesRead = 0
        for dayName in dayNames where TranscriptParser.isDayFolder(dayName) {
            let dayURL = root.appendingPathComponent(dayName, isDirectory: true)
            // Prefetch size/mtime with the listing: one batched call instead of
            // a stat syscall per file, which dominates a fully warm rescan.
            guard let fileURLs = try? fileManager.contentsOfDirectory(
                at: dayURL,
                includingPropertiesForKeys: Self.statKeys,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            var entries: [TranscriptEntry] = []
            for url in fileURLs where url.pathExtension == "md" {
                let file = url.lastPathComponent
                guard let info = TranscriptParser.parseFilename(file) else { continue }
                let verdict = markerVerdict(at: url, previous: cache, filesRead: &filesRead)
                if let verdict {
                    fresh.verdicts[url.path] = verdict
                    if verdict.isMarker { continue }
                }
                entries.append(
                    TranscriptEntry(
                        url: url,
                        filename: file,
                        timeString: info.timeString,
                        sessionId8: info.sessionId8,
                        chunkSeq: info.chunkSeq
                    ))
            }
            guard !entries.isEmpty else { continue }
            entries.sort { $0.filename > $1.filename }
            days.append(TranscriptDay(date: dayName, entries: entries))
        }
        days.sort { $0.date > $1.date }
        return TranscriptScanResult(days: days, cache: fresh, filesRead: filesRead)
    }

    static let statKeys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]

    /// The legacy marker files contain only fixed frontmatter, one heading, and
    /// the marker, so anything larger is a real transcript and never read.
    /// Returns nil when the file cannot be stat'd (treated as a real entry, and
    /// not cached, so the next scan retries).
    private static func markerVerdict(
        at url: URL,
        previous: TranscriptScanCache,
        filesRead: inout Int
    ) -> TranscriptScanCache.Verdict? {
        guard
            let values = try? url.resourceValues(forKeys: Set(statKeys)),
            let size = values.fileSize,
            let mtime = values.contentModificationDate
        else {
            return nil
        }
        if let cached = previous.verdicts[url.path],
           cached.size == size, cached.mtime == mtime
        {
            return cached
        }
        guard size <= 4_096 else {
            return TranscriptScanCache.Verdict(size: size, mtime: mtime, isMarker: false)
        }
        filesRead += 1
        let isMarker =
            (try? String(contentsOf: url, encoding: .utf8))
            .flatMap(TranscriptParser.parse)?.isEmpty ?? false
        return TranscriptScanCache.Verdict(size: size, mtime: mtime, isMarker: isMarker)
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
    @ObservationIgnored private var scanCache = TranscriptScanCache()
    @ObservationIgnored private var lastScanAt: Date?
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var watchDebounce: Task<Void, Never>?

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
        scanCache = TranscriptScanCache()
        lastScanAt = nil
        stopWatching()
        guard url != nil else { return }
        refresh()
        startWatching()
    }

    public func refresh() {
        guard let root else { return }
        // One scan at a time; a request that lands mid-scan runs once after.
        guard !isScanning else {
            rescanPending = true
            return
        }
        isScanning = true
        let cache = scanCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = TranscriptScanner.scan(root: root, cache: cache)
            await MainActor.run { [weak self] in
                guard let self, self.root == root else { return }
                self.scanCache = result.cache
                // @Observable fires on every set, equal or not — don't churn
                // the list when a watcher event turns out to be a no-op.
                if self.days != result.days { self.days = result.days }
                self.isScanning = false
                self.lastScanAt = Date()
                if self.rescanPending {
                    self.rescanPending = false
                    self.refresh()
                }
            }
        }
    }

    /// Refresh unless a scan finished within `interval`. For view `onAppear`,
    /// which fires on every visit to the pane.
    public func refreshIfStale(olderThan interval: TimeInterval = 1.0) {
        if let lastScanAt, Date().timeIntervalSince(lastScanAt) < interval { return }
        refresh()
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
            self?.scheduleWatchRefresh()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        watcher = source
    }

    /// A finished chunk can fire several directory events in a row; collapse
    /// them into one scan.
    private func scheduleWatchRefresh() {
        watchDebounce?.cancel()
        watchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func stopWatching() {
        watchDebounce?.cancel()
        watchDebounce = nil
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
    }
}
