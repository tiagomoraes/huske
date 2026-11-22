// A recording as Shortcuts and Siri see it: its title, date, length, where it
// is in the phone → Mac pipeline, and — once the Mac has sent it back — its
// transcript. Enumerable, so Shortcuts also gets a "Find Recordings" action
// that filters and sorts on these properties for free.

import AppIntents
import Foundation

struct RecordingEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Recording", numericFormat: "\(placeholder: .int) recordings")
    static let defaultQuery = RecordingQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Date")
    var date: Date

    @Property(title: "Duration")
    var duration: Measurement<UnitDuration>

    @Property(title: "Status")
    var status: String

    @Property(title: "Is Transcribed")
    var isTranscribed: Bool

    /// The Mac's transcript Markdown (timecoded runs); empty until it is back.
    @Property(title: "Transcript")
    var transcript: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(duration.value))",
            image: .init(systemName: "waveform"))
    }

    init(recording: Recording, status: String) {
        id = recording.id
        title = recording.title
        date = recording.startedAt
        duration = Measurement(value: recording.duration.rounded(), unit: .seconds)
        self.status = status
        isTranscribed = recording.isTranscriptAvailable
        transcript = recording.transcript?.markdown ?? ""
    }
}

struct RecordingQuery: EnumerableEntityQuery, EntityStringQuery {
    init() {}

    func entities(for identifiers: [RecordingEntity.ID]) async throws -> [RecordingEntity] {
        await IntentLibrary.entities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RecordingEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await IntentLibrary.entities()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.transcript.localizedCaseInsensitiveContains(needle)
        }
    }

    func suggestedEntities() async throws -> [RecordingEntity] {
        Array(await IntentLibrary.entities().prefix(12))
    }

    func allEntities() async throws -> [RecordingEntity] {
        await IntentLibrary.entities()
    }
}

/// The library as intents read it: saved recordings, newest first. Intents run
/// in the app's process (launched in the background if needed), so this is
/// the same store the app shows.
@MainActor
enum IntentLibrary {
    static func entities() -> [RecordingEntity] {
        let app = AppModel.shared
        return app.library.recordings
            .filter { $0.capture != .inProgress }
            .map { RecordingEntity(recording: $0, status: app.sync.badge(for: $0).label) }
    }

    static func entity(id: String) -> RecordingEntity? {
        let app = AppModel.shared
        return app.library.recording(id: id).map { RecordingEntity(recording: $0, status: app.sync.badge(for: $0).label) }
    }

    static func recording(id: String) -> Recording? {
        AppModel.shared.library.recording(id: id)
    }

    /// Newest recording with a transcript.
    static func latestTranscribed() -> Recording? {
        AppModel.shared.library.recordings.first { $0.isTranscriptAvailable }
    }
}
