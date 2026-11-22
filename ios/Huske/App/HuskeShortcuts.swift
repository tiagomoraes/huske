import AppIntents

/// Siri / Shortcuts / Spotlight / Action button: "Start a Huske recording".
struct HuskeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start a \(.applicationName) recording",
                "Record with \(.applicationName)",
                "Start recording in \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
