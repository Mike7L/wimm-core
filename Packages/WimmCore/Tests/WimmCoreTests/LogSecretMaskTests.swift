import XCTest
import WimmDomain

final class LogSecretMaskTests: XCTestCase {
    func testMasksGeminiKeyInURL() {
        let line = "GET https://generativelanguage.googleapis.com/v1beta/models?key=AIzaTestOnlyNotARealKey000000000&pageSize=1"
        let masked = LogSecretMask.mask(line)
        XCTAssertFalse(masked.contains("AIzaTestOnlyNotARealKey000000000"))
        XCTAssertTrue(masked.contains("key=AIza<redacted>&pageSize=1"))
    }

    func testMasksOpenAIStyleKeyAndBearerToken() {
        let masked = LogSecretMask.mask("auth sk-testonly1234567890 header Authorization: Bearer abc.def-123")
        XCTAssertFalse(masked.contains("sk-testonly1234567890"))
        XCTAssertFalse(masked.contains("abc.def-123"))
        XCTAssertTrue(masked.contains("sk-<redacted>"))
        XCTAssertTrue(masked.contains("Bearer <token>"))
    }

    func testLeavesOrdinaryTextUnchanged() {
        let line = "Transcribed task-42 in 3.2s; AIza alone is not a key"
        XCTAssertEqual(LogSecretMask.mask(line), line)
    }
}
