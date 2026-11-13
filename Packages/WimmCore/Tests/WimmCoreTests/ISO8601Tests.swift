import XCTest
@testable import WimmDomain

/// `ISO8601` replaced ~30 per-call formatter constructions. Sidecars, logs and
/// sync timestamps are compared and parsed across versions, so the shared
/// formatters must produce byte-identical output to what each call site built.
final class ISO8601Tests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_000_000.512)

    func testDefaultMatchesAFreshFormatter() {
        XCTAssertEqual(ISO8601.string(from: date), ISO8601DateFormatter().string(from: date))
    }

    func testFractionalMatchesAFreshFormatter() {
        let fresh = ISO8601DateFormatter()
        fresh.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(ISO8601.stringWithFractionalSeconds(from: date), fresh.string(from: date))
    }

    func testParseEitherAcceptsBothShapes() {
        let plain = ISO8601.string(from: date)
        let fractional = ISO8601.stringWithFractionalSeconds(from: date)
        XCTAssertEqual(ISO8601.parseEither(plain)?.timeIntervalSince1970, 1_791_000_000)
        XCTAssertEqual(
            ISO8601.parseEither(fractional)?.timeIntervalSince1970 ?? 0,
            1_791_000_000.512,
            accuracy: 0.001
        )
        XCTAssertNil(ISO8601.parseEither("not a date"))
    }
}
