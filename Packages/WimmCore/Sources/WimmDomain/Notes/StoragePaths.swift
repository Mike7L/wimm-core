import Foundation

/// Pure path resolution for the on-disk note store. Single source of truth
/// for the base directory and the relative-path scheme used by persisted
/// JSON (notes, attachments, segments). `FileStore` (same module)
/// delegates here so both layers resolve identically.
public enum StoragePaths {
    public static func baseDirectory() -> URL {
        // Allow tests or power users to override the base directory via env var.
        if let override = ProcessInfo.processInfo.environment["WIMM_BASE_DIR"],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true).resolvingSymlinksInPath()
        }

        // A test process never defaults to the real library. Tests that did
        // not set WIMM_BASE_DIR used to list all ~6.8k real notes, and on
        // 2026-10-23 one ran the WIMM_TEST_MODE mock analysis over a real
        // note and stamped "Mocked Note Title" into its sidecar.
        if isTestProcess {
            return isolatedTestBaseDirectory
        }

        #if os(iOS)
            // iOS: Try App Group for sharing with extensions, otherwise use Documents
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.wimm.app"
            ) {
                return container.appendingPathComponent("Wimm", isDirectory: true).absoluteURL
            }
            // Fallback to Documents directory
            if let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first {
                return documents.appendingPathComponent("Wimm", isDirectory: true).absoluteURL
            }
            // Last resort
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Wimm", isDirectory: true).absoluteURL
        #else
            // macOS: Store under ~/Library/Application Support/Wimm (platform-conventional)
            let fm = FileManager.default
            if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return support.appendingPathComponent("Wimm", isDirectory: true).absoluteURL
            }
            // Fallback
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("Wimm", isDirectory: true).absoluteURL
        #endif
    }

    /// XCTest is loaded, or the process runs with the `WIMM_TEST_MODE`
    /// mocks (e.g. a CLI child spawned by a test).
    public static var isTestProcess: Bool {
        isRunningUnderXCTest || ProcessInfo.processInfo.environment["WIMM_TEST_MODE"] != nil
    }

    static let isRunningUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

    /// One empty directory per test process.
    public static let isolatedTestBaseDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wimm-test-library-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        .resolvingSymlinksInPath()

    public static func relativePath(for url: URL) -> String {
        let base = baseDirectory().path
        let target = url.path
        if target.hasPrefix(base) {
            var rel = String(target.dropFirst(base.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            return rel
        }
        return target
    }

    public static func resolveRelativePath(_ path: String) -> URL {
        if path.contains("://"), let url = URL(string: path) {
            return url
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return baseDirectory().appendingPathComponent(path)
    }
}
