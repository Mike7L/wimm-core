import Foundation
import XCTest
@testable import WimmDomain

/// 2026-10-23: a test without WIMM_BASE_DIR ran the WIMM_TEST_MODE mock
/// analysis over a real library note and wrote "Mocked Note Title" into its
/// sidecar. A test process must never resolve to the real library.
final class StoragePathsTestIsolationTests: XCTestCase {
    private var savedBaseDir: String?

    override func setUp() {
        savedBaseDir = ProcessInfo.processInfo.environment["WIMM_BASE_DIR"]
        unsetenv("WIMM_BASE_DIR")
    }

    override func tearDown() {
        if let savedBaseDir { setenv("WIMM_BASE_DIR", savedBaseDir, 1) } else { unsetenv("WIMM_BASE_DIR") }
    }

    func testTestProcessWithoutOverrideGetsAnIsolatedLibrary() {
        XCTAssertTrue(StoragePaths.isTestProcess)
        let base = StoragePaths.baseDirectory()
        XCTAssertEqual(base, StoragePaths.isolatedTestBaseDirectory)
        XCTAssertFalse(base.path.contains("/Library/Application Support/Wimm"), base.path)
        XCTAssertFalse(FileStore.recordingsDirectory().path.contains("/Library/Application Support/Wimm"))
    }

    func testExplicitOverrideStillWins() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wimm-override-\(UUID().uuidString)")
        setenv("WIMM_BASE_DIR", dir.path, 1)
        XCTAssertEqual(StoragePaths.baseDirectory().path, dir.resolvingSymlinksInPath().path)
    }
}
