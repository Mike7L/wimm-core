import XCTest

@testable import WimmInfrastructure

final class PromptLoaderTests: XCTestCase {
    func testLoadsPromptFromModuleBundle() {
        let prompt = PromptLoader.load("transcription_note_card_extraction")
        XCTAssertFalse(prompt.hasPrefix("Error:"), "prompt should resolve from the bundle")
        XCTAssertFalse(prompt.isEmpty)
    }

    func testReplacesVariables() {
        let prompt = PromptLoader.load(
            "transcription_standard_prompt", variables: ["lang_hint": "ru"])
        XCTAssertFalse(prompt.hasPrefix("Error:"))
        XCTAssertFalse(prompt.contains("{{lang_hint}}"))
    }

    func testLoadsAgentChatPrompt() {
        let prompt = PromptLoader.load("agent_chat")
        XCTAssertFalse(prompt.hasPrefix("Error:"))
        XCTAssertFalse(prompt.isEmpty)
    }

    func testMissingPromptReturnsError() {
        XCTAssertTrue(PromptLoader.load("non_existent_prompt").hasPrefix("Error: Failed to load prompt 'non_existent_prompt'"))
    }
}
