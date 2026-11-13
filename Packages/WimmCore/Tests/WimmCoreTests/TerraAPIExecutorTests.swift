import Foundation
import XCTest
@testable import WimmSecretary

final class TerraAPIExecutorTests: XCTestCase {
    func testPaidResponsePreservesUsageAndRejectsTruncation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TerraFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let executor = TerraAPIExecutor(session: session, apiKey: "fixture-not-a-real-key")
        for finish in ["stop", "length", "unknown-cost"] {
            var request = SecretaryExecutionRequest(workspaceRoot: directory, runDirectory: directory, prompt: finish,
                kind: .pass, wimmCLI: "/usr/bin/true", budgetUSD: 1, model: "openai/gpt-6.1-terra", timeout: 10, effort: "medium")
            request.systemPrompt = "fixture policy"
            let result = try await executor.run(request, onEvent: { _ in })
            XCTAssertEqual(result.isError, finish == "length")
            XCTAssertEqual(result.tokensIn, 100)
            XCTAssertEqual(result.tokensOut, 20)
            XCTAssertEqual(result.costUSD, finish == "unknown-cost" ? nil : 0.001)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("request.json"))) as! [String: Any]
            XCTAssertEqual(saved["model"] as? String, "openai/gpt-6.1-terra")
            XCTAssertEqual((saved["reasoning"] as? [String: String])?["effort"], "medium")
            XCTAssertNil(saved["tools"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("provider-response.json").path))
        }
    }
}

private final class TerraFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                data = body
            } else { throw NSError(domain: "fixture", code: 1) }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let mode = (body["messages"] as! [[String: String]]).last!["content"]!
            var usage: [String: Any] = ["prompt_tokens": 100, "completion_tokens": 20]
            if mode != "unknown-cost" { usage["cost"] = 0.001 }
            let response = try JSONSerialization.data(withJSONObject: ["usage": usage,
                "choices": [["finish_reason": mode == "length" ? "length" : "stop", "message": ["content": "{}"]]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
