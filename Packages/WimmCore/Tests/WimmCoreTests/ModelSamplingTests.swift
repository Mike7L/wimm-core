import XCTest
@testable import WimmInfrastructure

final class ModelSamplingTests: XCTestCase {
    func testDeprecatedGeminiOverridesAreOmittedAcrossProviderRoutes() throws {
        struct Body: Encodable { let temperature: Double? }
        for model in ["gemini-3-flash-preview", "gemini-3.5-flash", "gemini-3.8-flash", "google/gemini-3.8-flash", "models/gemini-3.8-flash"] {
            let data = try JSONEncoder().encode(Body(temperature: ModelSampling.temperature(0, model: model)))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["temperature"], model)
        }
    }

    func testOlderGeminiAndOtherModelsKeepTheirChosenSampling() {
        for model in ["gemini-2.5-flash", "google/gemini-2.5-pro", "openai/gpt-4o", "claude-sonnet-4-5", "gemini-30-test"] {
            XCTAssertEqual(ModelSampling.temperature(0.7, model: model), 0.7, model)
            XCTAssertEqual(ModelSampling.temperature(0, model: model), 0, model)
            XCTAssertNil(ModelSampling.temperature(nil, model: model), model)
        }
    }
}
