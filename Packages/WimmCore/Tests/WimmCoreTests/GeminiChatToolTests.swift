import XCTest
import os
@testable import WimmInfrastructure

final class GeminiChatToolTests: XCTestCase {
    private var oldKey: String?
    private var oldKeys: String?
    private var oldPrivate: String?
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        oldKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        oldKeys = ProcessInfo.processInfo.environment["GEMINI_API_KEYS"]
        oldPrivate = ProcessInfo.processInfo.environment["WIMM_PRIVATE_MODE"]
        setenv("GEMINI_API_KEY", "fixture-key-never-sent-to-network", 1)
        setenv("GEMINI_API_KEYS", "fixture-key-never-sent-to-network", 1)
        setenv("WIMM_PRIVATE_MODE", "0", 1)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatFixtureProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel(); session = nil
        ChatFixtureProtocol.handler = nil
        restore("GEMINI_API_KEY", oldKey); restore("GEMINI_API_KEYS", oldKeys); restore("WIMM_PRIVATE_MODE", oldPrivate)
        super.tearDown()
    }

    func testToolsRoundTripPreservesSignatureAndIDAndStreamsOnlyVisibleText() async throws {
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let executed = OSAllocatedUnfairLock(initialState: 0)
        ChatFixtureProtocol.handler = { request in
            let body = try Self.body(request)
            let step = requests.withLock { $0 += 1; return $0 }
            XCTAssertTrue(request.url?.path.contains("gemini-3.8-flash:streamGenerateContent") == true)
            XCTAssertNotNil(body["tools"])
            let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
            XCTAssertNil(config["temperature"], "Provider default must remain omitted on every continuation")
            XCTAssertEqual((config["thinkingConfig"] as? [String: String])?["thinkingLevel"], "medium",
                           "The final answer needs the same reasoning level as tool selection")
            if step == 1 {
                return try Self.sse(parts: [["functionCall": ["name": "previous_note", "args": [:], "id": "call-1"],
                                            "thoughtSignature": "opaque-fixture-signature"]])
            }
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            XCTAssertEqual(contents.count, 3)
            let modelParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
            XCTAssertEqual(modelParts[0]["thoughtSignature"] as? String, "opaque-fixture-signature")
            let results = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
            let response = try XCTUnwrap(results[0]["functionResponse"] as? [String: Any])
            XCTAssertEqual(response["id"] as? String, "call-1")
            XCTAssertEqual((response["response"] as? [String: String])?["result"], "[N:fixture] Живут в Киле.")
            return try Self.sse(parts: [["text": "Hidden reasoning", "thought": true], ["text": "Теперь понятен контекст."]])
        }
        let tool = GeminiChatStream.Tool(name: "previous_note", description: "Read", parametersJSON: "{\"type\":\"object\"}") { _ in
            executed.withLock { $0 += 1 }
            return "[N:fixture] Живут в Киле."
        }
        let output = try await Self.collect(chat(model: "gemini-3.8-flash").stream(system: "Read first", messages: [.init(role: .user, text: "О предыдущей заметке")], temperature: 0.4, thinking: .mediumLevel, tools: [tool]))
        XCTAssertEqual(output, "Теперь понятен контекст.")
        XCTAssertEqual(requests.withLock { $0 }, 2)
        XCTAssertEqual(executed.withLock { $0 }, 1)
    }

    func testExplicitTemperatureRemainsAvailableToOtherCallers() async throws {
        ChatFixtureProtocol.handler = { request in
            let config = try XCTUnwrap(try Self.body(request)["generationConfig"] as? [String: Any])
            XCTAssertEqual(config["temperature"] as? Double, 0.7)
            return try Self.sse(parts: [["text": "Ответ."]])
        }
        let output = try await Self.collect(chat().stream(system: "", messages: [], temperature: 0.7))
        XCTAssertEqual(output, "Ответ.")
    }

    func testUnknownToolNeverExecutesAndLoopIsBounded() async throws {
        let requests = OSAllocatedUnfairLock(initialState: 0)
        ChatFixtureProtocol.handler = { _ in
            requests.withLock { $0 += 1 }
            return try Self.sse(parts: [["functionCall": ["name": "read", "args": [:]]]])
        }
        let tool = GeminiChatStream.Tool(name: "read", description: "Read", parametersJSON: "{\"type\":\"object\"}") { _ in "evidence" }
        do { _ = try await Self.collect(chat().stream(system: "", messages: [], temperature: 0, tools: [tool])); XCTFail("must stop") }
        catch { XCTAssertTrue(error.localizedDescription.contains("предел")) }
        XCTAssertEqual(requests.withLock { $0 }, 8)
        do { _ = try await Self.collect(chat().stream(system: "", messages: [], temperature: 0)); XCTFail("must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("недоступный")) }
    }

    func testCancellationDuringReadDoesNotSendLateEvidence() async throws {
        let gate = ChatReadGate()
        let requests = OSAllocatedUnfairLock(initialState: 0)
        ChatFixtureProtocol.handler = { _ in
            requests.withLock { $0 += 1 }
            return try Self.sse(parts: [["functionCall": ["name": "read", "args": [:]]]])
        }
        let tool = GeminiChatStream.Tool(name: "read", description: "Read", parametersJSON: "{\"type\":\"object\"}") { _ in await gate.read() }
        let stream = chat().stream(system: "", messages: [], temperature: 0, tools: [tool])
        let task = Task.detached { @Sendable [stream] in try await GeminiChatToolTests.collect(stream) }
        try await waitForRead(gate)
        task.cancel()
        await gate.release()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests.withLock { $0 }, 1)
    }

    func testPrivacyChangeDuringReadRefusesFollowupCloudRequest() async throws {
        let gate = ChatReadGate()
        let requests = OSAllocatedUnfairLock(initialState: 0)
        ChatFixtureProtocol.handler = { _ in
            requests.withLock { $0 += 1 }
            return try Self.sse(parts: [["functionCall": ["name": "read", "args": [:]]]])
        }
        let tool = GeminiChatStream.Tool(name: "read", description: "Read", parametersJSON: "{\"type\":\"object\"}") { _ in await gate.read() }
        let stream = chat().stream(system: "", messages: [], temperature: 0, tools: [tool])
        let task = Task.detached { @Sendable [stream] in try await GeminiChatToolTests.collect(stream) }
        try await waitForRead(gate)
        setenv("WIMM_PRIVATE_MODE", "1", 1)
        await gate.release()
        do { _ = try await task.value; XCTFail("must refuse") }
        catch { XCTAssertTrue(PrivateMode.isRefusal(error)) }
        XCTAssertEqual(requests.withLock { $0 }, 1)
    }

    private func chat(model: String = "gemini-tools-fixture") -> GeminiChatStream {
        GeminiChatStream(model: model, operation: .conversation, origin: "GeminiChatToolTests",
                         transport: LLMTransport(geminiRotator: APIKeyRotator()), session: session)
    }
    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""; for try await piece in stream { text += piece }; return text
    }
    private func waitForRead(_ gate: ChatReadGate) async throws {
        for _ in 0..<200 { if await gate.started { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("tool never started"); await gate.release(); throw URLError(.timedOut)
    }
    private func restore(_ key: String, _ value: String?) { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
    private static func sse(parts: [[String: Any]]) throws -> Data {
        let object: [String: Any] = ["candidates": [["content": ["role": "model", "parts": parts]]],
                                   "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15]]
        return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n").utf8)
    }
    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let direct = request.httpBody { data = direct }
        else {
            let input = try XCTUnwrap(request.httpBodyStream); input.open(); defer { input.close() }
            var out = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = input.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; out.append(contentsOf: buffer.prefix(count)) }
            data = out
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor ChatReadGate {
    var started = false
    private var continuation: CheckedContinuation<String, Never>?
    func read() async -> String { started = true; return await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: "late evidence"); continuation = nil }
}

private final class ChatFixtureProtocol: URLProtocol {
    private static let handlerState = OSAllocatedUnfairLock<(@Sendable (URLRequest) throws -> Data)?>(initialState: nil)
    static var handler: (@Sendable (URLRequest) throws -> Data)? {
        get { handlerState.withLock { $0 } }
        set { handlerState.withLock { $0 = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                                        httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
