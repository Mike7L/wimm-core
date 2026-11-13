import XCTest
@testable import WimmInfrastructure

final class GeminiTranscriptionAdapterTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.transcriptionInlineDataMaxMB)
        GeminiAdapterURLProtocol.handler = nil
        super.tearDown()
    }

    func testPreparedUploadURLKeepsMiniFileUnchanged() async {
        let mini = URL(fileURLWithPath: "/tmp/Wimm_example_mini.m4a")

        let result = await GeminiTranscriptionAdapter.preparedUploadURL(for: mini)

        XCTAssertEqual(result, mini)
    }

    func testPreparedUploadURLKeepsMicroFileUnchanged() async {
        let micro = URL(fileURLWithPath: "/tmp/Wimm_example_micro.m4a")

        let result = await GeminiTranscriptionAdapter.preparedUploadURL(for: micro)

        XCTAssertEqual(result, micro)
    }

    func testLargePreparedFileUsesFilesAPIAndFileDataPrompt() async throws {
        UserDefaults.standard.set(1.0, forKey: DefaultsKey.transcriptionInlineDataMaxMB)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wimm_large_micro_\(UUID().uuidString)_micro.m4a")
        try Data(repeating: 0x1, count: 1 * 1024 * 1024 + 1).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let lock = NSLock()
        var requests: [URLRequest] = []
        GeminiAdapterURLProtocol.handler = { request in
            lock.withLock { requests.append(request) }

            let url = try XCTUnwrap(request.url)
            if url.path == "/upload/v1beta/files" {
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Goog-Upload-URL": "https://upload.test/session"]
                ))
                return (response, Data())
            }
            if url.host == "upload.test" {
                return try Self.jsonResponse(url: url, object: [
                    "file": [
                        "name": "files/test-audio",
                        "uri": "https://generativelanguage.googleapis.com/v1beta/files/test-audio",
                        "mimeType": "audio/mp4",
                        "state": "ACTIVE",
                    ],
                ])
            }
            if url.path.contains(":generateContent") {
                let body = try Self.bodyData(from: request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
                let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
                XCTAssertNotNil(parts.first { $0["file_data"] != nil })
                XCTAssertNil(parts.first { $0["inline_data"] != nil })
                return try Self.jsonResponse(url: url, object: [
                    "candidates": [["content": ["parts": [["text": "Recovered transcript"]]]]],
                ])
            }
            if request.httpMethod == "DELETE" {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (response, Data())
            }
            throw URLError(.unsupportedURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiAdapterURLProtocol.self]
        let adapter = GeminiTranscriptionAdapter(
            apiKey: "test-key",
            modelName: "gemini-test",
            session: URLSession(configuration: configuration)
        )

        let text = try await adapter.transcribeFile(at: file)

        XCTAssertEqual(text, "Recovered transcript")
        let captured = lock.withLock { requests }
        XCTAssertEqual(captured.map(\.httpMethod), ["POST", "POST", "POST", "DELETE"])
    }

    func testEmptyGenerateResponseThrowsNoText() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wimm_empty_\(UUID().uuidString)_micro.m4a")
        try Data([0x1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        GeminiAdapterURLProtocol.handler = { request in
            try Self.jsonResponse(url: try XCTUnwrap(request.url), object: [
                "candidates": [["content": ["parts": [["text": "   "]]]]],
            ])
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiAdapterURLProtocol.self]
        let adapter = GeminiTranscriptionAdapter(
            apiKey: "test-key",
            modelName: "gemini-test",
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await adapter.transcribeFile(at: file)
            XCTFail("Expected an empty transcription to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, ErrorDomain.noText)
        }
    }

    private static func jsonResponse(url: URL, object: Any) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, try JSONSerialization.data(withJSONObject: object))
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class GeminiAdapterURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
