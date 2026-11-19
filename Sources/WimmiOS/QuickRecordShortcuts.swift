#if os(iOS)
import AppIntents

/// Makes "Start Recording" available to Siri, Spotlight, Shortcuts and the
/// Action button without the user building a shortcut first.
struct WimmAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record in \(.applicationName)",
                "Запиши в \(.applicationName)",
                "Начни запись в \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}
#endif
