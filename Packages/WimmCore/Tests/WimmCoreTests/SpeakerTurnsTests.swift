import XCTest
@testable import WimmInfrastructure

final class SpeakerTurnsTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> SpeakerTurns.Word {
        SpeakerTurns.Word(text: text, start: start, end: end)
    }

    func testGroupsWordsIntoTurnsNumberedByFirstAppearance() {
        let words = [word("Привет", 0.0, 0.5), word("бабушка", 0.6, 1.2),
                     word("Здравствуй", 2.0, 2.8), word("внучек", 2.9, 3.4),
                     word("Как", 4.0, 4.2), word("ты", 4.3, 4.5)]
        let spans = [SpeakerTurns.Span(speaker: "S7", start: 0, end: 1.5),
                     SpeakerTurns.Span(speaker: "S2", start: 1.8, end: 3.6),
                     SpeakerTurns.Span(speaker: "S7", start: 3.9, end: 5)]
        let turns = SpeakerTurns.turns(words: words, spans: spans)
        XCTAssertEqual(turns.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(turns.map(\.text), ["Привет бабушка", "Здравствуй внучек", "Как ты"])
        XCTAssertEqual(turns[1].start, 2.0)
        XCTAssertEqual(turns[1].end, 3.4)
    }

    /// Quiet speech is often outside every span (~35 % of word time on phone calls).
    func testUncoveredWordTakesNearestSpanWithinReach() {
        let spans = [SpeakerTurns.Span(speaker: "A", start: 0, end: 1),
                     SpeakerTurns.Span(speaker: "B", start: 3, end: 4)]
        let turns = SpeakerTurns.turns(words: [word("раз", 0.2, 0.6), word("два", 2.3, 2.6)], spans: spans)
        XCTAssertEqual(turns.map(\.speaker), [1, 2])
    }

    func testFarUncoveredWordStaysWithPreviousSpeaker() {
        let spans = [SpeakerTurns.Span(speaker: "A", start: 0, end: 1),
                     SpeakerTurns.Span(speaker: "B", start: 20, end: 21)]
        let turns = SpeakerTurns.turns(words: [word("раз", 0.2, 0.6), word("два", 9, 9.5)], spans: spans)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "раз два")
    }

    func testOverlapBeatsNearness() {
        let spans = [SpeakerTurns.Span(speaker: "A", start: 0, end: 1.1),
                     SpeakerTurns.Span(speaker: "B", start: 1.1, end: 3)]
        let turns = SpeakerTurns.turns(words: [word("слово", 1.0, 2.0)], spans: spans)
        XCTAssertEqual(turns.first?.speaker, 1)
        XCTAssertEqual(SpeakerTurns.speaker(for: word("слово", 1.0, 2.0), in: spans), "B")
    }

    func testRecordRoundTripsThroughSidecarValue() throws {
        let record = SpeakerTurnsRecord(
            speakers: 2, engine: "fluidaudio-offline", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            turns: [.init(speaker: 1, start: 0, end: 1.234, text: "Привет"),
                    .init(speaker: 2, start: 1.5, end: 2, text: "Здравствуй")])
        let json = try JSONSerialization.data(withJSONObject: record.sidecarValue)
        let decoded = try XCTUnwrap(SpeakerTurnsRecord(sidecarValue: try JSONSerialization.jsonObject(with: json)))
        XCTAssertEqual(decoded.speakers, 2)
        XCTAssertEqual(decoded.createdAt, record.createdAt)
        XCTAssertEqual(decoded.turns.map(\.text), ["Привет", "Здравствуй"])
        XCTAssertEqual(decoded.turns[0].end, 1.23)
        XCTAssertTrue(decoded.isMultiSpeaker)
    }

    func testSpeakersVariantIsRenderedWithLabels() {
        let record = SpeakerTurnsRecord(
            speakers: 2, engine: "fluidaudio-offline",
            turns: [.init(speaker: 1, start: 0, end: 1, text: "Привет"),
                    .init(speaker: 2, start: 1, end: 2, text: "Здравствуй"),
                    .init(speaker: 1, start: 2, end: 3, text: "Как дела")])
        let sidecar: [String: Any] = ["transcription": [
            "transcript": "Привет Здравствуй Как дела",
            SpeakerTurnsRecord.sidecarKey: record.sidecarValue,
        ]]
        let variants = NoteTranscriptVariant.variants(fromSidecar: sidecar)
        let speakers = variants.first { $0.kind == .speakers(count: 2) }
        XCTAssertEqual(speakers?.rendered { "Голос \($0)" }.text,
                       "Голос 1: Привет\n\nГолос 2: Здравствуй\n\nГолос 1: Как дела")
    }

    func testSingleSpeakerRecordIsNotShown() {
        let record = SpeakerTurnsRecord(speakers: 1, engine: "fluidaudio-offline", turns: [])
        let sidecar: [String: Any] = ["transcription": [
            "transcript": "Диктовка", SpeakerTurnsRecord.sidecarKey: record.sidecarValue]]
        XCTAssertFalse(NoteTranscriptVariant.variants(fromSidecar: sidecar).contains {
            if case .speakers = $0.kind { return true } else { return false }
        })
    }
}

final class LiveTranscriptSegmenterTests: XCTestCase {
    private let rate = 16_000

    /// Speech-like noise at `level`, or silence.
    private func audio(_ parts: [(seconds: Double, level: Float)]) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return parts.flatMap { part in
            (0..<Int(part.seconds * Double(rate))).map { _ in
                part.level == 0 ? 0 : Float.random(in: -part.level...part.level, using: &generator)
            }
        }
    }

    func testKeepsShortWindowLive() {
        XCTAssertNil(LiveTranscriptSegmenter().cutPoint(audio([(4, 0.2), (0.5, 0), (0.5, 0.2)])))
    }

    func testCutsInsideTheLatestPause() throws {
        let samples = audio([(6.5, 0.2), (0.5, 0), (2, 0.2), (0.6, 0), (1.5, 0.2)])
        let cut = try XCTUnwrap(LiveTranscriptSegmenter().cutPoint(samples))
        let seconds = Double(cut) / Double(rate)
        XCTAssertGreaterThan(seconds, 9.0)
        XCTAssertLessThan(seconds, 9.6)
    }

    func testIgnoresPauseInsideTailGuard() {
        // The only pause is in the last 0.8 s: maybe a breath, so nothing freezes yet.
        XCTAssertNil(LiveTranscriptSegmenter().cutPoint(audio([(7.5, 0.2), (0.5, 0)])))
    }

    func testForcesACutInLongUnbrokenSpeech() throws {
        let cut = try XCTUnwrap(LiveTranscriptSegmenter().cutPoint(audio([(14, 0.2)])))
        let seconds = Double(cut) / Double(rate)
        XCTAssertGreaterThanOrEqual(seconds, 6)
        XCTAssertLessThan(seconds, 13.3)
    }

    /// A far-away voice: its pauses are quiet relative to it, not to an absolute level.
    func testFindsPauseInQuietRecording() throws {
        let samples = audio([(7, 0.02), (0.5, 0.001), (2, 0.02)])
        let cut = try XCTUnwrap(LiveTranscriptSegmenter().cutPoint(samples))
        XCTAssertEqual(Double(cut) / Double(rate), 7.25, accuracy: 0.3)
    }

    func testSilenceDetection() {
        let segmenter = LiveTranscriptSegmenter()
        XCTAssertTrue(segmenter.isSilent(audio([(2, 0.0005)])))
        XCTAssertFalse(segmenter.isSilent(audio([(1.5, 0.0005), (0.5, 0.05)])))
    }
}
