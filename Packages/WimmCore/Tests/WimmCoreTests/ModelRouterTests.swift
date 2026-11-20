import XCTest
@testable import WimmInfrastructure

final class ModelRouterTests: XCTestCase {
    func testRoutesGeminiOpenRouterAndParakeetFallback() {
        XCTAssertEqual(ModelRouter.provider(for: "gemini-3.5-flash"), .gemini)
        XCTAssertEqual(ModelRouter.provider(for: "models/gemini-2.5-flash"), .gemini)
        XCTAssertEqual(ModelRouter.provider(for: "openai/gpt-4o-mini"), .openrouter)
        // Parakeet keeps falling back to .gemini (TranscriptKind.ofModel inspects prefix).
        XCTAssertEqual(ModelRouter.provider(for: ParakeetModel.ultra), .gemini)
    }

    func testStaleOnDeviceIdentifiersNeverRouteToOpenRouter() {
        for id in ["local/mlx-community/qwen2.5-1.5b", "LOCAL/foo", "apple/on-device", "APPLE/on-device"] {
            XCTAssertNotEqual(ModelRouter.provider(for: id), .openrouter, id)
        }
    }

    func testFactoryRejectsUnsupportedOnDeviceModels() throws {
        for id in ["apple", " apple/on-device ", "Apple/test", "local/mlx-community/qwen"] {
            XCTAssertThrowsError(try ModelProviderFactory.create(capability: .think, identifier: id)) { error in
                XCTAssertEqual(error as? ModelProviderError, .unsupportedOnDeviceModel(id.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        let gemini = try ModelProviderFactory.create(capability: .think, identifier: "gemini-3.5-flash")
        XCTAssertEqual(gemini.provider, .gemini)
        let openRouter = try ModelProviderFactory.create(capability: .think, identifier: "openai/gpt-4o-mini")
        XCTAssertEqual(openRouter.provider, .openrouter)
    }
}
