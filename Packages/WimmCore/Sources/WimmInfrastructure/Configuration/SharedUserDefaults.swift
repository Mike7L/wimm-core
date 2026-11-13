import Foundation

public enum SharedUserDefaults {
    // Shared defaults for model/settings sync across app targets.
    // App Group name can be overridden for local builds/tests.
    public static let defaultSuiteName = "group.com.wimm.app"

    /// Suite used by a test process that did not pick its own.
    ///
    /// `group.com.wimm.app` is the *real* app's settings: on macOS a test
    /// process opening it writes straight into the user's model choices.
    /// `TranscriptionCoordinatorTests` reset the transcription model to
    /// `gemini-2.5-flash` on every tearDown and `ViewModelHUDPresenterTests`
    /// cleared the transcriber engine — so every test run before a release
    /// silently reverted the app's settings. Under XCTest the default is
    /// therefore never the real suite.
    public static let testSuiteName = "wimm.tests.shared-defaults"

    public static var suiteName: String {
        if let raw = ProcessInfo.processInfo.environment["WIMM_DEFAULTS_SUITE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return isRunningUnderXCTest ? isolatedTestSuiteName : defaultSuiteName
    }

    public static var store: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static let isRunningUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

    /// Wiped once per test process, so a run never inherits the last one's values.
    private static let isolatedTestSuiteName: String = {
        UserDefaults(suiteName: testSuiteName)?.removePersistentDomain(forName: testSuiteName)
        return testSuiteName
    }()
}
