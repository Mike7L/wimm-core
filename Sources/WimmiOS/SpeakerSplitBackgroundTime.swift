#if os(iOS)
import UIKit
import WimmInfrastructure

/// Keeps a speaker split alive on the iPhone. The split after a Parakeet run is detached from
/// the processing job, so the job's own background time no longer covers it: without this a
/// split already computing was frozen with the app and its result lost.
@MainActor
enum SpeakerSplitBackgroundTime {
    static func install() {
        SpeakerTurnsBackfill.backgroundTimeHolder = { name, expired in
            let token = await MainActor.run {
                let token = Token()
                token.begin(name, expired: expired)
                return token
            }
            return { await token.end() }
        }
    }

    @MainActor
    final class Token {
        private var id: UIBackgroundTaskIdentifier = .invalid

        func begin(_ name: String, expired: @escaping @Sendable () -> Void) {
            id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // The work is cancelled; the time must be handed back right here, or iOS kills the app.
                expired()
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}

/// Catches up splits that never landed (the app was killed mid-split, or the diarizer failed),
/// once per launch — a kill means a relaunch, and the live path covers everything else. Only
/// while the hear model is Parakeet: otherwise the iPhone would download the models unasked.
@MainActor
enum SpeakerSplitCatchUp {
    private static var started = false

    static func runOnceIfNeeded() {
        guard !started,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ParakeetModel.isParakeet(Config.transcribeModel) else { return }
        started = true
        let language = UserDefaults.standard.string(forKey: DefaultsKey.transcriptionLanguage) ?? "Auto"
        Task.detached(priority: .utility) {
            // Out of the launch: sync, the share inbox and the queue go first.
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            await SpeakerTurnsBackfill.runPending(languages: [language])
        }
    }
}
#endif
