// Recording App Intents shared by the app and the widget extension.
//
// The extension only *references* these (the Live Activity's buttons, the
// Control Center / Action button control). They are `LiveActivityIntent` or
// `AudioRecordingIntent`, so the system runs `perform()` in the app's process,
// launching it in the background if needed — that is what lets the Action
// button start a recording without opening Huske, the way Voice Memos does.
// There, the app has registered a handler with `RecordingCommandCenter`; in
// the extension none ever is, so a stray call reports `.unavailable`.
//
// Everything Shortcuts, Siri and Spotlight list is in Huske/Intents (app
// target only): an intent compiled into both targets can be resolved through
// the extension, which has no App Shortcuts and no recorder.
//
// iOS keeps an `AudioRecordingIntent`'s background recording only while a Live
// Activity shows it, and only a `LiveActivityIntent` may start one from the
// background — so the control's intent is both. `RecorderController.start`
// requests the activity before it opens the microphone.

import AppIntents
import Foundation

enum RecordingCommand: Equatable, Sendable {
    /// A new recording, optionally named. No-op if one is already running.
    case start(title: String?)
    /// Start if idle, otherwise stop and save — the Action button.
    case toggleRecording
    /// `nil` targets whatever is recording now.
    case togglePause(recordingID: String?)
    /// `nil` targets whatever is recording now.
    case stop(recordingID: String?)
}

enum RecordingCommandOutcome: Equatable, Sendable {
    case started(recordingID: String)
    case alreadyRecording(recordingID: String)
    case paused
    case resumed
    case stopped(recordingID: String)
    case notRecording
    case failed(String)
    /// No recorder in this process (the widget extension).
    case unavailable
}

@MainActor
enum RecordingCommandCenter {
    typealias Handler = (RecordingCommand) async -> RecordingCommandOutcome

    private static var handler: Handler?
    private static var waiting: [CheckedContinuation<Handler, Never>] = []

    /// Called once by the app at launch. Commands that arrived before the app
    /// finished launching (an intent can be the reason it launched) run now.
    static func register(_ newHandler: @escaping Handler) {
        handler = newHandler
        let queued = waiting
        waiting.removeAll()
        for continuation in queued { continuation.resume(returning: newHandler) }
    }

    static func send(_ command: RecordingCommand) async -> RecordingCommandOutcome {
        if let handler { return await handler(command) }
        // The extension never registers: answer instead of waiting forever.
        if Bundle.main.bundleURL.pathExtension == "appex" { return .unavailable }
        let handler = await withCheckedContinuation { waiting.append($0) }
        return await handler(command)
    }
}

/// A failure the person can act on, in their words. App Intents shows it as
/// the action's error (Shortcuts, Siri, the Action button banner).
struct RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }

    static func from(_ outcome: RecordingCommandOutcome) -> RecordingIntentError? {
        switch outcome {
        case let .failed(message): return RecordingIntentError(message: message)
        case .unavailable: return RecordingIntentError(message: "Open Huske to record.")
        default: return nil
        }
    }
}

// MARK: - the Control Center / Action button control

/// What the "Huske Record" control runs: one press starts a recording in the
/// background, the next stops and saves it. Hidden from Shortcuts — there the
/// app-only `StartOrStopRecordingIntent` does the same. An intent compiled into
/// both targets may be *resolved* through the extension (Siri, Spotlight), so
/// everything the Shortcuts app lists lives in the app target instead.
struct RecordControlIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start or Stop Recording"
    static let description = IntentDescription("Starts a Huske recording, or stops and saves the one in progress.")
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        let outcome = await RecordingCommandCenter.send(.toggleRecording)
        if let error = RecordingIntentError.from(outcome) { throw error }
        return .result()
    }
}

// MARK: - Live Activity buttons (bound to one recording)

struct PauseResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume This Recording"
    static let description = IntentDescription("Pauses the Huske recording in progress, or resumes it.")
    static let isDiscoverable = false

    @Parameter(title: "Recording ID")
    var recordingID: String

    init() {}

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    func perform() async throws -> some IntentResult {
        _ = await RecordingCommandCenter.send(.togglePause(recordingID: recordingID))
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop This Recording"
    static let description = IntentDescription("Stops and saves the Huske recording in progress.")
    static let isDiscoverable = false

    @Parameter(title: "Recording ID")
    var recordingID: String

    init() {}

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    func perform() async throws -> some IntentResult {
        _ = await RecordingCommandCenter.send(.stop(recordingID: recordingID))
        return .result()
    }
}
