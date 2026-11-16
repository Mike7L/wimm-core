import XCTest
@testable import WimmStudio

final class VikIdeaPhraseTests: XCTestCase {
    func testShortIdeaPhraseOpensAnIdeaReviewTask() {
        XCTAssertEqual(VikCodeTask.extract(from: "идея: автобусы как такси."), "Проработай идею: автобусы как такси.")
        XCTAssertEqual(VikCodeTask.extract(from: "Посмотри идею — склад в гараже"), "Проработай идею: склад в гараже")
        XCTAssertEqual(VikCodeTask.extract(from: "оцени идею"), "Проработай идею, сказанную в этой заметке до обращения.")
        XCTAssertEqual(VikCodeTask.extract(from: "Идея."), "Проработай идею, сказанную в этой заметке до обращения.")
        for text in ["идеи есть?", "идеальный план", "у меня идея", "какая идея была вчера", "оцени заметку"] {
            XCTAssertNil(VikCodeTask.extract(from: text), text)
        }
    }

    func testIdeaSpokenBeforeTheAddressReachesTheDraft() throws {
        let note = "Автобусы можно вызывать как такси. Алёна, идея."
        let task = try XCTUnwrap(VikCodeTask.extract(from: try XCTUnwrap(VikRequest.extract(from: note))))
        let prompt = VikCodeTask.prompt(task: task, note: note, source: "")
        XCTAssertTrue(prompt.contains("Проработай идею, сказанную в этой заметке до обращения."))
        XCTAssertTrue(prompt.contains("Автобусы можно вызывать как такси."))
    }
}
