import Foundation
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SpeakerVoiceTagsTests: XCTestCase {
    private func split(voices: [SpeakerTurnsRecord.VoiceTag]) -> SpeakerTurnsRecord {
        SpeakerTurnsRecord(speakers: 2, engine: "test", createdAt: Date(timeIntervalSince1970: 1_790_000_000), turns: [
            .init(speaker: 1, start: 0, end: 2, text: "Мам, давай конкретно."),
            .init(speaker: 2, start: 2, end: 5, text: "Пора собираться."),
            .init(speaker: 1, start: 5, end: 6, text: "Хорошо."),
        ], voices: voices)
    }

    func testVoiceTagsRoundTripThroughTheSidecarValue() throws {
        let record = split(voices: [
            .init(voice: 1, card: "P000", score: 0.574, windows: 15),
            .init(voice: 2, card: nil, score: 0.29, windows: 7),
        ])
        let read = try XCTUnwrap(SpeakerTurnsRecord(sidecarValue: record.sidecarValue))
        XCTAssertEqual(read.voices, [
            .init(voice: 1, card: "P000", score: 0.57, windows: 15),
            .init(voice: 2, card: nil, score: 0.29, windows: 7),
        ])
        XCTAssertEqual(read.turns, record.turns)
        // An older record has no tags, and a value that is not a card id is not a card.
        var raw = record.sidecarValue
        raw["voices"] = [["voice": 1, "card": "мама", "windows": 4]]
        XCTAssertNil(SpeakerTurnsRecord(sidecarValue: raw)?.voices.first?.card)
        raw.removeValue(forKey: "voices")
        XCTAssertEqual(SpeakerTurnsRecord(sidecarValue: raw)?.voices, [])
    }

    func testTranscriptIsPrintedByVoiceOnlyForTheSameWords() {
        let tagged = split(voices: [.init(voice: 1, card: "P000", score: 0.57, windows: 15),
                                    .init(voice: 2, card: "P003", score: 0.66, windows: 15)])
        let transcript = "Мам, давай конкретно. Пора собираться.\nХорошо."
        XCTAssertEqual(MCPRecallServer.byVoice(transcript, split: tagged),
                       "[P000]: Мам, давай конкретно.\n\n[P003]: Пора собираться.\n\n[P000]: Хорошо.")
        XCTAssertNil(MCPRecallServer.byVoice("Другой текст.", split: tagged))
        XCTAssertEqual(MCPRecallServer.voicesLine(tagged)?.hasPrefix("voices: Голос 1 = [P000] 0.57; Голос 2 = [P003] 0.66 — "), true)

        let partly = split(voices: [.init(voice: 1, card: nil, score: 0.29, windows: 7),
                                    .init(voice: 2, card: "P003", score: 0.66, windows: 5)])
        XCTAssertEqual(MCPRecallServer.byVoice(transcript, split: partly)?.hasPrefix("Голос 1: Мам"), true)
        XCTAssertEqual(MCPRecallServer.voicesLine(partly)?.contains("Голос 1 = unknown (best 0.29)"), true)

        let same = split(voices: [.init(voice: 1, card: "P000", score: 0.6, windows: 9),
                                  .init(voice: 2, card: "P000", score: 0.55, windows: 9)])
        XCTAssertEqual(MCPRecallServer.voiceLabel(2, in: same), "[P000] голос 2")
        XCTAssertEqual(MCPRecallServer.voicesLine(split(voices: [])), "voices: 2, not compared with voice profiles")
    }

    func testVoiceCardsNameOnlyTheIdsOfThePacket() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let people: [String: Any] = ["cards": [
            ["id": "P000", "canonical": "Михаил", "relation": "автор заметок"],
            ["id": "P003", "canonical": "Анна", "relation": "мать"],
            ["id": "P004", "canonical": "Пётр"],
        ]]
        try JSONSerialization.data(withJSONObject: people).write(to: dir.appendingPathComponent("me.people.json"))
        let source = "date: 2026-11-12\nvoices: Голос 1 = [P000] 0.57; Голос 2 = [P003] 0.66 — on-device\n\n--- transcript ---\n[P004]: слова пользователя"
        XCTAssertEqual(SecretaryPacket.voiceCards(in: [source], document: dir.appendingPathComponent("me.md")),
                       ["P000": "Михаил — автор заметок", "P003": "Анна — мать"])
        XCTAssertEqual(SecretaryPacket.voiceCards(in: ["date: x\n\ntext"], document: dir.appendingPathComponent("me.md")), [:])
    }
}
