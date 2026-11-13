import XCTest
@testable import WimmInfrastructure

final class ParakeetModelTests: XCTestCase {
    func testRecognisesParakeetIdentifiers() {
        XCTAssertEqual(ParakeetModel.variant(from: "parakeet:ultra"), "ultra")
        XCTAssertEqual(ParakeetModel.variant(from: "  Parakeet:Ultra "), "ultra")
        XCTAssertTrue(ParakeetModel.isParakeet(ParakeetModel.ultra))
    }

    func testLeavesOtherModelsAlone() {
        // These must keep routing to their own engines.
        for id in ["gemini-3-flash-preview", "whisper:large-v3-turbo", "openai/gpt-4o-mini",
                   "local/parakeet-ultra", "apple/on-device", "parakeet:", ""] {
            XCTAssertNil(ParakeetModel.variant(from: id), id)
        }
    }

    func testSilenceNeedsBothLowConfidenceAndFewWords() {
        // Measured: the near-silent note in Auto and ru modes.
        XCTAssertTrue(ParakeetModel.looksLikeSilence(confidence: 0.591, words: 29, audioSeconds: 196.2))
        XCTAssertTrue(ParakeetModel.looksLikeSilence(confidence: 0.490, words: 6, audioSeconds: 196.2))
        XCTAssertTrue(ParakeetModel.looksLikeSilence(confidence: 0.95, words: 0, audioSeconds: 30))
        // Measured real speech, including the noisiest one (0.79 confidence, 73 wpm).
        XCTAssertFalse(ParakeetModel.looksLikeSilence(confidence: 0.951, words: 510, audioSeconds: 388.3))
        XCTAssertFalse(ParakeetModel.looksLikeSilence(confidence: 0.79, words: 650, audioSeconds: 532.5))
        // Quiet but real: low confidence alone is not enough.
        XCTAssertFalse(ParakeetModel.looksLikeSilence(confidence: 0.6, words: 40, audioSeconds: 60))
        // A short real phrase in a long note: few words alone is not enough.
        XCTAssertFalse(ParakeetModel.looksLikeSilence(confidence: 0.93, words: 5, audioSeconds: 120))
    }

    #if canImport(FluidAudio)
    func testScriptFilterOnlyWhenLanguageIsFixed() {
        XCTAssertEqual(ParakeetTranscriptionAdapter.scriptLanguage(for: "ru")?.rawValue, "ru")
        XCTAssertEqual(ParakeetTranscriptionAdapter.scriptLanguage(for: "Russian")?.rawValue, "ru")
        XCTAssertEqual(ParakeetTranscriptionAdapter.scriptLanguage(for: "de-DE")?.rawValue, "de")
        // "Auto" must not force an alphabet: German notes would come out in Cyrillic.
        XCTAssertNil(ParakeetTranscriptionAdapter.scriptLanguage(for: "Auto"))
        XCTAssertNil(ParakeetTranscriptionAdapter.scriptLanguage(for: ""))
    }

    func testKnownVariants() {
        XCTAssertNotNil(ParakeetTranscriptionAdapter.version(for: "ultra"))
        XCTAssertNil(ParakeetTranscriptionAdapter.version(for: "redux"))
    }
    #endif
}
