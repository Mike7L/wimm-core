import XCTest
@testable import WimmInfrastructure

final class LLMRetryPolicyTests: XCTestCase {
    func testShouldRetryStatusCode() {
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(statusCode: 429))
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(statusCode: 500))
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(statusCode: 502))
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(statusCode: 503))
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(statusCode: 504))
        XCTAssertFalse(LLMRetryPolicy.shouldRetry(statusCode: 400))
        XCTAssertFalse(LLMRetryPolicy.shouldRetry(statusCode: 404))
    }

    func testShouldRetryErrorForNetworkAndRetryableHTTP() {
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(error: URLError(.timedOut)))

        let retryable = NSError(domain: ErrorDomain.badStatus, code: 503, userInfo: [:])
        XCTAssertTrue(LLMRetryPolicy.shouldRetry(error: retryable))

        let nonRetryable = NSError(domain: ErrorDomain.badStatus, code: 400, userInfo: [:])
        XCTAssertFalse(LLMRetryPolicy.shouldRetry(error: nonRetryable))
    }

    func testRetryAfterParsingAndDelay() {
        XCTAssertEqual(LLMRetryPolicy.retryAfterSeconds(from: "12"), 12)
        XCTAssertNil(LLMRetryPolicy.retryAfterSeconds(from: "abc"))
        XCTAssertNil(LLMRetryPolicy.retryAfterSeconds(from: nil))

        let err = NSError(domain: ErrorDomain.badStatus, code: 503, userInfo: ["RetryAfterSec": 7])
        XCTAssertEqual(LLMRetryPolicy.delaySeconds(attempt: 1, error: err), 7)

        let noHeader = NSError(domain: ErrorDomain.badStatus, code: 503, userInfo: [:])
        XCTAssertEqual(LLMRetryPolicy.delaySeconds(attempt: 2, error: noHeader), 3.0, accuracy: 0.001)
    }
}

