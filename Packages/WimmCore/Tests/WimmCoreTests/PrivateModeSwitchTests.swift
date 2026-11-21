import XCTest
@testable import WimmInfrastructure

/// Studio's menu writes the switch; every reader (LLMTransport, CLI, MCP,
/// the web server) reads the same shared-suite key. Under XCTest the suite is
/// an isolated test suite, never the real app's settings.
final class PrivateModeSwitchTests: XCTestCase {
    override func setUpWithError() throws {
        if let raw = ProcessInfo.processInfo.environment["WIMM_PRIVATE_MODE"], !raw.isEmpty {
            throw XCTSkip("WIMM_PRIVATE_MODE overrides the stored switch in this run")
        }
    }

    override func tearDown() {
        PrivateMode.setStored(false)
        super.tearDown()
    }

    func testStoredSwitchTurnsTheKillSwitchOnAndOff() {
        XCTAssertNotEqual(SharedUserDefaults.suiteName, SharedUserDefaults.defaultSuiteName)
        PrivateMode.setStored(true)
        XCTAssertTrue(PrivateMode.isEnabled)
        XCTAssertThrowsError(try PrivateMode.checkCloudEgress(provider: "gemini")) {
            XCTAssertTrue(PrivateMode.isRefusal($0))
        }
        PrivateMode.setStored(false)
        XCTAssertFalse(PrivateMode.isEnabled)
        XCTAssertNoThrow(try PrivateMode.checkCloudEgress(provider: "gemini"))
    }
}
