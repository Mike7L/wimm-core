import XCTest
@testable import WimmStudio

final class ShouldersDialogueTests: XCTestCase {
    func testPlainReplyIsNotADialogue() {
        XCTAssertNil(ShouldersDialogue.lines("Как прошёл день?\nРасскажи про утро."))
    }

    func testTagsInEmojiAndWordsAndBold() throws {
        let lines = try XCTUnwrap(ShouldersDialogue.lines("""
        😇: Вечер — для семьи.
        **Демон:** Один созвон.
        Кто узнает?

        Ангел — Ты узнаешь.
        """))
        XCTAssertEqual(lines, [
            ShoulderLine(speaker: .angel, text: "Вечер — для семьи."),
            ShoulderLine(speaker: .demon, text: "Один созвон.\nКто узнает?"),
            ShoulderLine(speaker: .angel, text: "Ты узнаешь."),
        ])
    }

    func testStreamedLinesKeepTheSpeakerGoing() {
        XCTAssertEqual(ShouldersDialogue.streamedLine("😈: Ну и что?", previous: .angel),
                       ShoulderLine(speaker: .demon, text: "Ну и что?"))
        XCTAssertEqual(ShouldersDialogue.streamedLine("И ещё одно.", previous: .demon),
                       ShoulderLine(speaker: .demon, text: "И ещё одно."))
        XCTAssertEqual(ShouldersDialogue.streamedLine("Привет.", previous: nil),
                       ShoulderLine(speaker: .angel, text: "Привет."))
        XCTAssertNil(ShouldersDialogue.streamedLine("  ", previous: .angel))
        XCTAssertNil(ShouldersDialogue.streamedLine("😇:", previous: nil))
    }

    func testWordWithoutSeparatorIsNotATag() {
        XCTAssertNil(ShouldersDialogue.lines("Ангелы не спорят."))
    }

    func testEveryStyleAsksForTheSpokenLineFormat() {
        XCTAssertTrue(ShouldersStyle.original.prompt.hasPrefix("Ты кукловод двух персонажей"))
        for style in ShouldersStyle.allCases {
            XCTAssertTrue(style.prompt.contains("😇: текст\n😈: текст"), style.rawValue)
        }
        XCTAssertFalse(ShouldersStyle.listening.prompt.contains("Закончи ход вопросом"))
    }

    func testThinkingOffAsksForTheLeastTheModelAccepts() {
        XCTAssertNil(ShouldersThinking.off.config)
        XCTAssertNotNil(ShouldersThinking.model.config)
    }
}
