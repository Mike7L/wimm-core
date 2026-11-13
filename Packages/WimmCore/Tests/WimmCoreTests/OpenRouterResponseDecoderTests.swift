import XCTest
@testable import WimmInfrastructure

final class OpenRouterResponseDecoderTests: XCTestCase {
    func testDecodeOutputTextTopLevel() throws {
        let obj: [String: Any] = [
            "id": "resp_123",
            "output_text": "hello world"
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertEqual(OpenRouterResponseDecoder.decodeResponsesText(data), "hello world")
    }

    func testDecodeOutputArrayContentParts() throws {
        let obj: [String: Any] = [
            "output": [
                [
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "first"],
                        ["type": "other", "text": "ignored"],
                        ["type": "output_text", "text": "second"]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertEqual(OpenRouterResponseDecoder.decodeResponsesText(data), "first second")
    }

    func testDecodeResponseObjectContent() throws {
        let obj: [String: Any] = [
            "response": [
                "content": [
                    ["type": "output_text", "text": "alpha"],
                    ["type": "output_text", "text": "beta"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertEqual(OpenRouterResponseDecoder.decodeResponsesText(data), "alpha beta")
    }

    func testDecodeChoicesMessageString() throws {
        let obj: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "just text"
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertEqual(OpenRouterResponseDecoder.decodeResponsesText(data), "just text")
    }

    func testDecodeChoicesMessageParts() throws {
        let obj: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "hello"],
                        ["type": "text", "text": "there"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertEqual(OpenRouterResponseDecoder.decodeResponsesText(data), "hello there")
    }

    func testDecodeTypeOnlyReturnsMarker() throws {
        let obj: [String: Any] = [
            "output": [["content": [["type": "text"]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(OpenRouterResponseDecoder.decodeResponsesText(data))
    }

    func testDecodeNestedToolResult() throws {
        // Simulate a nested structure where text is under content -> tool_result -> content[]
        let obj: [String: Any] = [
            "output": [[
                "role": "assistant",
                "content": [
                    ["type": "tool_result", "content": [["type": "output_text", "text": "tool text"], ["text": "fallback"]]]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertEqual(OpenRouterResponseDecoder.decodeResponsesText(data), "tool text")
    }
}
