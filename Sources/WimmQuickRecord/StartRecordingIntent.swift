#if os(iOS)
import AppIntents

/// "Start recording" from outside the app: the Action button, a Control Center /
/// Lock Screen control, Siri or a Shortcut. Compiled into the app and the
/// widget extension; it always runs in the app (`openAppWhenRun`), where
/// `QuickRecord` hands it to `AppState`.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Opens Wimm and starts a new voice note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickRecord.request()
        return .result()
    }
}

/// Bridge from the intent to the running app. A request that arrives before
/// `AppState` exists waits until it registers its handler.
@MainActor
enum QuickRecord {
    private static var handler: (() async -> Void)?
    private static var pending = false

    static func request() {
        if let handler {
            Task { await handler() }
        } else {
            pending = true
        }
    }

    static func register(_ handler: @escaping () async -> Void) {
        self.handler = handler
        if pending {
            pending = false
            Task { await handler() }
        }
    }
}
#endif
