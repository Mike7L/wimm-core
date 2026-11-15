import XCTest
@testable import WimmInfrastructure

@MainActor
final class LLMTransportTests: XCTestCase {
    private var transport: LLMTransport?

    override func setUp() async throws {
        try await super.setUp()
        transport = LLMTransport(geminiRotator: APIKeyRotator(), openRouterRotator: OpenRouterKeyRotator())
    }

    override func tearDown() async throws {
        transport = nil
        try await super.tearDown()
    }

    func testMakeGeminiRequestUsesExplicitKey() async throws {
        let transport = try XCTUnwrap(transport)
        let request = try await transport.makeGeminiRequest(model: "gemini-test", timeout: 12.5, apiKey: "  test-key  ")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 12.5)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
    }

    func testMakeGeminiRequestNeverPutsKeyInURL() async throws {
        let transport = try XCTUnwrap(transport)
        let key = "AIzaTestOnlyNotARealKey000000000"
        let request = try await transport.makeGeminiRequest(
            model: "gemini-test", timeout: 5, apiKey: key, endpoint: "streamGenerateContent")

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains(key))
        XCTAssertFalse(url.contains("key="))
        XCTAssertNil(URLComponents(string: url)?.queryItems)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
    }

    func testMakeGeminiRequestFallsBackToRotatorWhenKeyMissing() async throws {
        let transport = try XCTUnwrap(transport)
        let request = try await transport.makeGeminiRequest(model: "gemini-test", timeout: 1, apiKey: "   ")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNotNil(request.url)
        XCTAssertTrue(request.url?.absoluteString.contains("models/gemini-test:generateContent") == true)
    }

    func testMakeOpenRouterRequestStripsQuotesAndSetsHeaders() async throws {
        let transport = try XCTUnwrap(transport)
        let request = try await transport.makeOpenRouterRequest(
            path: "chat/completions",
            timeout: 30,
            contentType: "application/json",
            apiKey: "  \"abc123\"  "
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testMakeOpenRouterRequestInvokesTracer() async throws {
        let transport = try XCTUnwrap(transport)
        let exp = expectation(description: "tracer")

        let tracer: @Sendable (String) -> Void = { message in
            if message.contains("current_prefix=abc123") {
                exp.fulfill()
            }
        }

        _ = try await transport.makeOpenRouterRequest(
            path: "responses",
            timeout: 5,
            tracer: tracer,
            apiKey: "abc123"
        )

        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testOpenRouterAttributionHeadersReadEnvironment() async throws {
        let transport = try XCTUnwrap(transport)
        let referer = "https://example.com"
        let title = "Wimm Tests"
        setenv("OPENROUTER_HTTP_REFERER", referer, 1)
        setenv("OPENROUTER_X_TITLE", title, 1)
        defer {
            unsetenv("OPENROUTER_HTTP_REFERER")
            unsetenv("OPENROUTER_X_TITLE")
        }

        let headers = transport.openRouterAttributionHeaders()
        XCTAssertEqual(headers["HTTP-Referer"], referer)
        XCTAssertEqual(headers["X-Title"], title)
    }
}
