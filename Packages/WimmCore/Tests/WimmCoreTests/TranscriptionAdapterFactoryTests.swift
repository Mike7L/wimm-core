import XCTest
import WimmInfrastructure

final class TranscriptionAdapterFactoryTests: XCTestCase {
    func testFromEnvironmentUsesPrimaryKey() {
        let env = ["WIMM_TRANSCRIBER": "openrouter"]
        XCTAssertEqual(TranscriptionEngine.fromEnvironment(env), .openrouter)
    }

    func testFromEnvironmentSupportsLegacyAliases() {
        XCTAssertEqual(
            TranscriptionEngine.fromEnvironment(["WIMM_TRANSCRIBE_ENGINE": "whisper"]),
            .whisper
        )
        XCTAssertEqual(
            TranscriptionEngine.fromEnvironment(["WIMM_TRANSCRIBER": "gemini"]),
            .gemini
        )
        XCTAssertEqual(
            TranscriptionEngine.fromEnvironment(["WIMM_TRANSCRIBER": "gemini-live"]),
            .geminiLive
        )
    }

    func testFromEnvironmentFallsBackToNative() {
        XCTAssertEqual(TranscriptionEngine.fromEnvironment([:]), .native)
        XCTAssertEqual(TranscriptionEngine.fromEnvironment(["WIMM_TRANSCRIBER": "unknown"]), .native)
    }
}
