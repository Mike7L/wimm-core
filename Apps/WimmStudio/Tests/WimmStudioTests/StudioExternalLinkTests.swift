import XCTest
@testable import WimmStudio

final class StudioExternalLinkTests: XCTestCase {
    func testWebAndMailLinksOpenWithoutAsking() throws {
        for raw in ["https://example.com/a", "http://example.com", "HTTPS://example.com", "mailto:anna@example.com"] {
            XCTAssertTrue(StudioExternalLink.opensWithoutAsking(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testOtherSchemesAsk() throws {
        for raw in ["ssh://host", "x-apple.systempreferences:com.apple.preference.security",
                    "vnc://host", "claude://code/new?prompt=x", "javascript:alert(1)", "relative/path"] {
            XCTAssertFalse(StudioExternalLink.opensWithoutAsking(try XCTUnwrap(URL(string: raw))), raw)
        }
    }
}
