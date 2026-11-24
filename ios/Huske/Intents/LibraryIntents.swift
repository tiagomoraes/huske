// Everything Shortcuts, Siri and Spotlight offer: start, stop and pause
// recordings, and read recordings and their transcripts. App target only, so
// the system always resolves and runs them in the app's process (see
// Shared/RecordingIntents.swift for the control's and Live Activity's own).

import AppIntents
import Foundation

// MARK: - start

/// "Start a Huske recording": records in the background — no app switch. The
/// Lock Screen and Dynamic Island show the recording while it runs.
struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription(
        "Starts a new Huske recording without opening the app. The Lock Screen and the Dynamic Island show it while it runs.",
        categoryName: "Recording")

    @Parameter(title: "Title", description: "Optional. Without one, the recording is named after the time it started.")
    var recordingTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a recording named \(\.$recordingTitle)")
    }

    init() {}

    func perform() async throws -> some IntentResult {
        let outcome = await RecordingCommandCenter.send(.start(title: recordingTitle))
        if let error = RecordingIntentError.from(outcome) { throw error }
        return .result()
    }
}

/// One run starts, the next stops and saves — for Settings › Action Button ›
/// Shortcut, Siri and Spotlight. (The control runs `RecordControlIntent`.)
struct StartOrStopRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start or Stop Recording"
    static let description = IntentDescription(
        "Starts a Huske recording, or stops and saves the one in progress. Made for the Action button.",
        categoryName: "Recording")

    init() {}

    func perform() async throws -> some IntentResult {
        let outcome = await RecordingCommandCenter.send(.toggleRecording)
        if let error = RecordingIntentError.from(outcome) { throw error }
        return .result()
    }
}

// MARK: - the recording in progress

struct StopCurrentRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    // App Store Connect refuses intent metadata that contains "Mac"
    // (ITMS-90626, Invalid Siri Support): say "computer" in descriptions,
    // display representations and phrases.
    static let description = IntentDescription(
        "Stops and saves the Huske recording in progress, and returns it. It's sent for transcription the next time your computer is nearby.",
        categoryName: "Recording")

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<RecordingEntity> {
        let outcome = await RecordingCommandCenter.send(.stop(recordingID: nil))
        if let error = RecordingIntentError.from(outcome) { throw error }
        guard case let .stopped(id) = outcome, let entity = await IntentLibrary.entity(id: id) else {
            throw RecordingIntentError(message: "Nothing is recording.")
        }
        return .result(value: entity)
    }
}

struct PauseOrResumeRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let description = IntentDescription(
        "Pauses the Huske recording in progress, or resumes it if it is paused.",
        categoryName: "Recording")

    init() {}

    func perform() async throws -> some IntentResult {
        let outcome = await RecordingCommandCenter.send(.togglePause(recordingID: nil))
        if let error = RecordingIntentError.from(outcome) { throw error }
        if outcome == .notRecording { throw RecordingIntentError(message: "Nothing is recording.") }
        return .result()
    }
}

// MARK: - transcripts

enum TranscriptFormat: String, AppEnum {
    case text
    case markdown

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Transcript Format")
    static let caseDisplayRepresentations: [TranscriptFormat: DisplayRepresentation] = [
        .text: DisplayRepresentation(title: "Text", subtitle: "What was said, paragraph by paragraph"),
        .markdown: DisplayRepresentation(title: "Markdown", subtitle: "With timecodes and sources"),
    ]
}

enum TranscriptText {
    /// The transcript in the requested shape, or nil if there is none yet.
    static func render(_ recording: Recording, as format: TranscriptFormat) -> String? {
        guard let markdown = recording.transcript?.markdown, !markdown.isEmpty else { return nil }
        switch format {
        case .markdown:
            return markdown
        case .text:
            return plain(markdown)
        }
    }

    /// Only what was said, one paragraph per run: no headings, timecodes or
    /// sources. What the transcript's Copy button and "as text" give. Falls
    /// back to the Markdown itself if nothing in it parses as speech.
    static func plain(_ markdown: String) -> String {
        let spoken = TranscriptParser.parse(markdown).compactMap { block -> String? in
            switch block {
            case let .run(_, _, text): return text.isEmpty ? nil : text
            case let .paragraph(text): return text.hasPrefix("_(") ? nil : text
            case .heading: return nil
            }
        }
        return spoken.isEmpty ? markdown : spoken.joined(separator: "\n\n")
    }

    /// Why a recording has no transcript, in the user's terms.
    static func missing(_ recording: Recording, status: String) -> String {
        if recording.transcript != nil {
            return "Your Mac found no speech in “\(recording.title)”."
        }
        // "Queued on your Mac" → "queued on your Mac": only the first letter.
        let state = status.prefix(1).lowercased() + status.dropFirst()
        return "“\(recording.title)” isn't transcribed yet (\(state)). Transcripts come back from your Mac."
    }
}

struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription(
        "Returns the transcript of your most recent Huske recording that has one.",
        categoryName: "Transcripts")

    @Parameter(title: "Format", default: .text)
    var format: TranscriptFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Get the latest transcript as \(\.$format)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let recording = await IntentLibrary.latestTranscribed(),
              let text = TranscriptText.render(recording, as: format) else {
            throw RecordingIntentError(
                message: "No transcripts yet. Recordings are transcribed on your Mac and come back to this iPhone.")
        }
        let excerpt = recording.transcript?.markdown.flatMap { TranscriptParser.excerpt($0, maxLength: 200) }
        let dialog = excerpt.map { "\(recording.title): \($0)" } ?? recording.title
        return .result(value: text, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct GetTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transcript"
    static let description = IntentDescription(
        "Returns the transcript of a Huske recording.",
        categoryName: "Transcripts")

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    @Parameter(title: "Format", default: .text)
    var format: TranscriptFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Get the transcript of \(\.$recording) as \(\.$format)")
    }

    init() {}

    init(recording: RecordingEntity) {
        self.recording = recording
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stored = await IntentLibrary.recording(id: recording.id) else {
            throw RecordingIntentError(message: "That recording is no longer on this iPhone.")
        }
        guard let text = TranscriptText.render(stored, as: format) else {
            throw RecordingIntentError(message: TranscriptText.missing(stored, status: recording.status))
        }
        return .result(value: text)
    }
}

// MARK: - open

struct OpenRecordingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Recording"
    static let description = IntentDescription("Opens a recording in Huske.", categoryName: "Transcripts")

    @Parameter(title: "Recording")
    var target: RecordingEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = AppModel.shared
        guard app.library.recording(id: target.id) != nil else {
            throw RecordingIntentError(message: "That recording is no longer on this iPhone.")
        }
        app.showingMac = false
        app.path = [target.id]
        return .result()
    }
}
