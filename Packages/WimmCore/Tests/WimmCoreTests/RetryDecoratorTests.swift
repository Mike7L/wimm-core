import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

final class RetryDecoratorTests: XCTestCase {
    func testRetriesOnRetryableErrorAndEventuallySucceeds() async throws {
        let flaky = FlakyAnalysis(
            failuresBeforeSuccess: 2,
            errorFactory: { NSError(domain: "HTTP", code: 429, userInfo: [NSLocalizedDescriptionKey: "rate limit"]) }
        )
        let retry = RetryDecorator(
            decoratee: flaky,
            maxAttempts: 3,
            initialDelayNanoseconds: 1_000_000
        )

        let card = try await retry.analyze(text: "hello")
        XCTAssertEqual(card.title, "ok")
        let calls = flaky.callCount
        XCTAssertEqual(calls, 3)
    }

    func testDoesNotRetryOnNonRetryableError() async throws {
        let alwaysBad = FlakyAnalysis(
            failuresBeforeSuccess: 5,
            errorFactory: { NSError(domain: "HTTP", code: 400, userInfo: [NSLocalizedDescriptionKey: "bad request"]) }
        )
        let retry = RetryDecorator(
            decoratee: alwaysBad,
            maxAttempts: 3,
            initialDelayNanoseconds: 1_000_000
        )

        do {
            _ = try await retry.analyze(text: "hello")
            XCTFail("Expected non-retryable error")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 400)
            let calls = alwaysBad.callCount
            XCTAssertEqual(calls, 1)
        }
    }
}

// FlakyAnalysis is defined in TestDoubles.swift
