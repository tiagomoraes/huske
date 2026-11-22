// App Intents shared by the app and the Live Activity extension.
//
// The Live Activity's Pause/Resume and Stop buttons are `LiveActivityIntent`s:
// the widget extension only *references* them; the system always runs
// `perform()` in the app's process (waking it in the background if needed).
// There, the app has registered a handler with `RecordingCommandCenter`. In
// the extension no handler is ever registered, so a stray call is a no-op.

import AppIntents
import Foundation

enum RecordingCommand: Equatable, Sendable {
    case start
    case togglePause(recordingID: String)
    case stop(recordingID: String)
}

@MainActor
enum RecordingCommandCenter {
    private static var handler: ((RecordingCommand) async -> Void)?
    private static var pending: [RecordingCommand] = []

    /// Called once by the app at launch. Commands that arrived before the app
    /// finished launching (an intent can be the reason it launched) run now.
    static func register(_ newHandler: @escaping (RecordingCommand) async -> Void) {
        handler = newHandler
        let queued = pending
        pending.removeAll()
        Task { @MainActor in
            for command in queued { await newHandler(command) }
        }
    }

    static func send(_ command: RecordingCommand) async {
        if let handler {
            await handler(command)
        } else {
            pending.append(command)
        }
    }
}

struct PauseResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let description = IntentDescription("Pauses the Huske recording in progress, or resumes it.")
    static let isDiscoverable = false

    @Parameter(title: "Recording ID")
    var recordingID: String

    init() {}

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    func perform() async throws -> some IntentResult {
        await RecordingCommandCenter.send(.togglePause(recordingID: recordingID))
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops and saves the Huske recording in progress.")
    static let isDiscoverable = false

    @Parameter(title: "Recording ID")
    var recordingID: String

    init() {}

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    func perform() async throws -> some IntentResult {
        await RecordingCommandCenter.send(.stop(recordingID: recordingID))
        return .result()
    }
}

/// "Start a Huske recording" — Siri, Shortcuts, Spotlight, the Action button
/// and (iOS 18+) a Control Center control. Recording must begin with the app
/// in the foreground, so the intent opens the app.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Opens Huske and starts a new recording.")
    static let openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingCommandCenter.send(.start)
        return .result()
    }
}
