import XCTest
import WimmInfrastructure
@testable import WimmStudio

final class StudioModelOptionsTests: XCTestCase {
    private func catalog(_ entries: [(String, [String])]) throws -> [GeminiModel] {
        let json = entries.map { ["name": "models/\($0.0)", "supportedGenerationMethods": $0.1] as [String: Any] }
        return try JSONDecoder().decode([GeminiModel].self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTextModelsKeepOnlyGeminiChatModels() throws {
        let models = try catalog([
            ("gemini-test-pro", ["generateContent"]),
            ("gemini-test-flash", ["generateContent", "countTokens"]),
            ("gemini-test-flash-tts", ["generateContent"]),
            ("gemini-test-flash-image", ["generateContent"]),
            ("gemini-test-flash-live-preview", ["bidiGenerateContent", "generateContent"]),
            ("gemini-embedding-test", ["embedContent"]),
            ("gemma-test", ["generateContent"]),
        ])
        XCTAssertEqual(StudioModelOptions.textModels(in: models), ["gemini-test-flash", "gemini-test-pro"])
    }

    func testListAlwaysOffersTheCurrentChoiceAndDefaultsOnce() {
        XCTAssertEqual(
            StudioModelOptions.list(catalog: ["gemini-a", "gemini-b"], current: " gemini-b ", defaults: ["gemini-a", ""]),
            ["gemini-b", "gemini-a"])
        XCTAssertEqual(StudioModelOptions.list(catalog: [], current: "typed/model", defaults: ["gemini-a"]),
                       ["typed/model", "gemini-a"])
    }

    func testCloudTranscriberRefusesEmptyAndOnDeviceIds() {
        XCTAssertTrue(StudioModelOptions.isCloudTranscriber("gemini-test-flash"))
        XCTAssertTrue(StudioModelOptions.isCloudTranscriber("openai/gpt-test-audio"))
        XCTAssertFalse(StudioModelOptions.isCloudTranscriber("  "))
        XCTAssertFalse(StudioModelOptions.isCloudTranscriber(ParakeetModel.ultra))
    }
}
