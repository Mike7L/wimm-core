import XCTest
@testable import WimmDomain

final class AppSandboxTests: XCTestCase {
    func testSandboxedWhenContainerIDIsPresent() {
        XCTAssertTrue(AppSandbox.isActive(environment: ["APP_SANDBOX_CONTAINER_ID": "com.micha.wimm.macos"]))
    }

    func testNotSandboxedWithoutContainerID() {
        XCTAssertFalse(AppSandbox.isActive(environment: [:]))
        XCTAssertFalse(AppSandbox.isActive(environment: ["HOME": "/Users/x"]))
    }
}
