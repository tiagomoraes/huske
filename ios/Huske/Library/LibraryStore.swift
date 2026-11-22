// The recordings library: a JSON index plus one audio file per recording,
// both under Application Support/Huske (excluded from iCloud backup — the
// copy that matters lives on the user's Mac).

import Foundation
import Observation

struct LibrarySection: Identifiable, Equatable {
    /// Start of the local calendar day.
    let day: Date
    let recordings: [Recording]
    var id: Date { day }
}

@MainActor
@Observable
final class LibraryStore {
    /// Newest first.
    private(set) var recordings: [Recording] = []
    /// Set when the index could not be read; the app shows it rather than
    /// silently starting an empty library over the old one.
    private(set) var loadError: String?

    let rootDirectory: URL
    let audioDirectory: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private let fileManager = FileManager.default

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.audioDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        self.indexURL = rootDirectory.appendingPathComponent("library.json")
        prepareDirectories()
        load()
    }

    /// The app's real library location.
    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Huske", isDirectory: true)
    }

    // MARK: queries

    func recording(id: String) -> Recording? {
        recordings.first { $0.id == id }
    }

    func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.fileName)
    }

    /// File name + URL for a new recording's audio.
    func newAudioFile(id: String, fileExtension: String = "m4a") -> (fileName: String, url: URL) {
        let name = "\(id).\(fileExtension)"
        return (name, audioDirectory.appendingPathComponent(name))
    }

    /// Recordings grouped by local calendar day, newest day first.
    func sections(calendar: Calendar = .current) -> [LibrarySection] {
        LibraryStore.group(recordings, calendar: calendar)
    }

    nonisolated static func group(_ recordings: [Recording], calendar: Calendar) -> [LibrarySection] {
        let byDay = Dictionary(grouping: recordings) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { day in
            LibrarySection(day: day, recordings: byDay[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    var titles: [String] { recordings.map(\.title) }

    // MARK: mutations

    func insert(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.append(recording)
        sortAndSave()
    }

    /// Mutates one recording in place and persists. No-op for unknown IDs.
    func update(_ id: String, _ mutate: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var copy = recordings[index]
        mutate(&copy)
        guard copy != recordings[index] else { return }
        recordings[index] = copy
        save()
    }

    /// Mutates every recording matching `predicate`, saving once.
    func updateAll(where predicate: (Recording) -> Bool, _ mutate: (inout Recording) -> Void) {
        var changed = false
        for index in recordings.indices where predicate(recordings[index]) {
            var copy = recordings[index]
            mutate(&copy)
            if copy != recordings[index] {
                recordings[index] = copy
                changed = true
            }
        }
        if changed { save() }
    }

    func rename(_ id: String, to proposed: String) {
        guard let title = RecordingTitle.normalized(proposed) else { return }
        update(id) { $0.title = title }
    }

    /// Removes the recording and its audio file.
    func delete(_ id: String) {
        guard let recording = recording(id: id) else { return }
        try? fileManager.removeItem(at: audioURL(for: recording))
        recordings.removeAll { $0.id == id }
        save()
    }

    /// Replaces the whole library (demo seeding, tests).
    func replaceAll(with newRecordings: [Recording]) {
        recordings = newRecordings
        sortAndSave()
    }

    // MARK: persistence

    private func prepareDirectories() {
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private func load() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let index = try Self.decoder.decode(LibraryIndex.self, from: data)
            recordings = index.recordings.sorted { $0.startedAt > $1.startedAt }
        } catch {
            // Keep the unreadable file aside instead of overwriting it.
            let backup = indexURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.copyItem(at: indexURL, to: backup)
            loadError = "The recordings list couldn't be read. A copy was kept as \(backup.lastPathComponent)."
        }
    }

    private func sortAndSave() {
        recordings.sort { $0.startedAt > $1.startedAt }
        save()
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(LibraryIndex(version: 1, recordings: recordings))
            // Readable after first unlock so background sync can work while locked.
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            loadError = "Couldn't save the recordings list: \(error.localizedDescription)"
        }
    }

    private struct LibraryIndex: Codable {
        var version: Int
        var recordings: [Recording]
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
