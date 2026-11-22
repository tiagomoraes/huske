import AppIntents

/// What Huske offers Siri, Spotlight, the Shortcuts app and the Action button
/// (Settings › Action Button › Shortcut › Huske) with no setup. Every other
/// action — Get Transcript, Open Recording, Find Recordings — is in the
/// Shortcuts app's Huske section.
struct HuskeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartOrStopRecordingIntent(),
            phrases: [
                "Start or stop a \(.applicationName) recording",
                "Toggle \(.applicationName) recording",
            ],
            shortTitle: "Record or Stop",
            systemImageName: "record.circle")
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start a \(.applicationName) recording",
                "Record with \(.applicationName)",
                "Start recording in \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic")
        AppShortcut(
            intent: StopCurrentRecordingIntent(),
            phrases: [
                "Stop the \(.applicationName) recording",
                "Stop recording in \(.applicationName)",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle")
        AppShortcut(
            intent: PauseOrResumeRecordingIntent(),
            phrases: [
                "Pause the \(.applicationName) recording",
                "Resume the \(.applicationName) recording",
            ],
            shortTitle: "Pause or Resume",
            systemImageName: "pause.circle")
        AppShortcut(
            intent: GetLatestTranscriptIntent(),
            phrases: [
                "Get my latest \(.applicationName) transcript",
                "What was said in my last \(.applicationName) recording",
            ],
            shortTitle: "Latest Transcript",
            systemImageName: "text.quote")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
