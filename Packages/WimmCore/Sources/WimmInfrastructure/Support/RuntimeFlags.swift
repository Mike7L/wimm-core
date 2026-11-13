import Foundation

public enum RuntimeFlags {
    /// Global switch for running the app in "test mode".
    ///
    /// Intended usage:
    /// - `swift test` can enable it via `WIMM_TEST_MODE=1`.
    /// - XCTest runs are auto-detected via `XCTestConfigurationFilePath`.
    /// - App can optionally set it for deterministic headless behavior.
    public static var isTestModeEnabled: Bool {
#if WIMM_TEST_MODE
        return true
#else
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        guard let raw = getenv("WIMM_TEST_MODE") else { return false }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
#endif
    }
}
