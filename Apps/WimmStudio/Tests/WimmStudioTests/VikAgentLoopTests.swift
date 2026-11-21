import XCTest
import os
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

/// Alyona's real prompt, message and read tools through the real Gemini tool
/// loop, with the cloud replaced by a scripted model. Checks the wiring a unit
/// test of either side cannot: a search hit's ID reaches `read_note`, the read
/// evidence reaches the model, and the answer streams out. No network.
final class VikAgentLoopTests: XCTestCase {
    private var saved: [String: String?] = [:]
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        for key in ["GEMINI_API_KEY", "GEMINI_API_KEYS", "WIMM_PRIVATE_MODE"] { saved[key] = ProcessInfo.processInfo.environment[key] }
        setenv("GEMINI_API_KEY", "fixture-key-never-sent-to-network", 1)
        setenv("GEMINI_API_KEYS", "fixture-key-never-sent-to-network", 1)
        setenv("WIMM_PRIVATE_MODE", "0", 1)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedGemini.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel(); session = nil
        ScriptedGemini.handler = nil
        for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
        super.tearDown()
    }

    func testSearchThenReadThenAnswerThroughTheRealLoop() async throws {
        let source = StoragePaths.baseDirectory().appendingPathComponent("Wimm_2026-11-06_19-00-00_CURRENT.aac")
        let asked = try XCTUnwrap(FileStore.recordingDateFromFileName(source))
        let library = RecallLibrary([
            RecallNote(id: "old-kiel", date: asked.addingTimeInterval(-40 * 86400), kind: "text", title: nil, summary: nil,
                       text: "Тётя Роза переехала в Киль весной.", filePath: "/fixture/old-kiel.txt"),
        ])
        let tools = VikContextTools(document: "# Документ\n\n## Семья\n\nПусто.", source: source, asOf: asked.addingTimeInterval(5),
                                    isAllowed: { true }, files: { [] }, library: { library })
        let context = try await tools.preloaded()
        let message = VikAssistant.message(note: "Алёна, куда переехала тётя Роза?", context: context,
                                           query: "куда переехала тётя Роза?", now: asked)
        let step = OSAllocatedUnfairLock(initialState: 0)
        ScriptedGemini.handler = { request in
            let body = try ScriptedGemini.body(request)
            let n = step.withLock { $0 += 1; return $0 }
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            switch n {
            case 1:
                let system = ((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]])?.first?["text"]
                XCTAssertEqual(system, VikAssistant.prompt)
                let first = try XCTUnwrap((contents[0]["parts"] as? [[String: String]])?.first?["text"])
                XCTAssertTrue(first.contains("<now>") && first.contains("## Семья"), "Clock and preloaded outline go first")
                let declared = ((body["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])?
                    .compactMap { $0["name"] as? String } ?? []
                XCTAssertTrue(declared.contains("search_notes") && declared.contains("my_recent_replies"))
                return try ScriptedGemini.sse([["functionCall": ["name": "search_notes", "args": ["query": "Роза Киль"], "id": "s1"]]])
            case 2:
                let result = try ScriptedGemini.lastResult(contents)
                XCTAssertTrue(result.contains("old-kiel"), result)
                return try ScriptedGemini.sse([["functionCall": ["name": "read_note", "args": ["id": "old-kiel"], "id": "r1"]]])
            default:
                let result = try ScriptedGemini.lastResult(contents)
                XCTAssertTrue(result.contains("переехала в Киль"), result)
                return try ScriptedGemini.sse([["text": "В Киль, весной [N:old-kiel]."]])
            }
        }
        let chat = GeminiChatStream(model: "gemini-3.8-flash", operation: .conversation, origin: "VikAgentLoopTests",
                                    transport: LLMTransport(geminiRotator: APIKeyRotator()), session: session)
        var answer = ""
        for try await piece in chat.stream(system: VikAssistant.prompt, messages: [.init(role: .user, text: message)],
                                           thinking: .lowLevel, tools: tools.tools) { answer += piece }
        XCTAssertEqual(answer, "В Киль, весной [N:old-kiel].")
        XCTAssertEqual(VikAssistant.withoutCitations(answer), "В Киль, весной.")
        XCTAssertEqual(step.withLock { $0 }, 3)
        let evidence = await tools.transcript()
        XCTAssertTrue(evidence.contains("### search_notes") && evidence.contains("### read_note"),
                      "The saved exchange keeps what was read")
    }
}

private final class ScriptedGemini: URLProtocol {
    private static let state = OSAllocatedUnfairLock<(@Sendable (URLRequest) throws -> Data)?>(initialState: nil)
    static var handler: (@Sendable (URLRequest) throws -> Data)? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                                                        headerFields: ["Content-Type": "text/event-stream"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func sse(_ parts: [[String: Any]]) throws -> Data {
        let object: [String: Any] = ["candidates": [["content": ["role": "model", "parts": parts]]],
                                     "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15]]
        return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n").utf8)
    }

    static func lastResult(_ contents: [[String: Any]]) throws -> String {
        let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
        let response = try XCTUnwrap(parts.first?["functionResponse"] as? [String: Any])
        return try XCTUnwrap((response["response"] as? [String: String])?["result"])
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = input.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
