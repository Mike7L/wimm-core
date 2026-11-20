import Foundation
import XCTest
@testable import WimmSecretary

final class SecretaryReviewQueueTests: XCTestCase {
    private let queue = """
    # Очередь проверки

    ## Открытые вопросы

    - **Q58. Работа.** Куда поставить абзац про клуб? [S12]
      - a) Оставить в «Работе»
        - плюс: рядом с датами
        - минус: глава уже длинная
      - b) Перенести в «Друзья»,
        где уже есть история клуба
      - Рекомендую: b — там читатель её ищет.
    - Q57. Как звали собаку Лены Орловой?
      продолжение вопроса [S3]
    - Q56. Один вариант не делает вопрос выбором.
      - a) Только так
    - Q55. Рекомендация без такого варианта.
      - 1) Да
      - 2) Нет
      - Рекомендую: 3 — так проще.

    ## Закрытые

    - Q1. Старый вопрос
      - a) Да
      - b) Нет
    """

    func testOptionsRecommendationAndProsConsAreRead() throws {
        let questions = SecretaryReviewQueue.openQuestions(in: queue)
        XCTAssertEqual(questions.map(\.number), [58, 57, 56, 55])
        let q = questions[0]
        XCTAssertEqual(q.text, "Работа. Куда поставить абзац про клуб? [S12]")
        XCTAssertEqual(q.sources, ["S12"])
        XCTAssertEqual(q.options, [
            .init(key: "a", label: "Оставить в «Работе»", pros: ["рядом с датами"], cons: ["глава уже длинная"]),
            .init(key: "b", label: "Перенести в «Друзья», где уже есть история клуба"),
        ])
        XCTAssertEqual(q.recommend, "b")
        XCTAssertEqual(q.why, "там читатель её ищет.")
    }

    func testFreeTextQuestionsReadAsBefore() {
        let questions = SecretaryReviewQueue.openQuestions(in: queue)
        XCTAssertEqual(questions[1], .init(number: 57, text: "Как звали собаку Лены Орловой? продолжение вопроса [S3]", sources: ["S3"]))
        XCTAssertNil(questions[2].options)
        XCTAssertEqual(questions[2].text, "Один вариант не делает вопрос выбором.")
        XCTAssertEqual(questions[3].options?.map(\.key), ["1", "2"])
        XCTAssertNil(questions[3].recommend)
        XCTAssertNil(questions[3].why)
    }

    func testNestedQuestionItemIsStillAQuestion() {
        let questions = SecretaryReviewQueue.openQuestions(in: "## Открытые вопросы\n\n- Тема\n  - Q7. Вложенный вопрос?\n")
        XCTAssertEqual(questions.map(\.number), [7])
    }

    func testOneTapAnswerNamesTheOption() {
        XCTAssertEqual(SecretaryReviewQueue.answerText(for: .init(key: "b", label: "Перенести в «Друзья»")),
                       "вариант b: Перенести в «Друзья»")
    }

    func testAnOldSavedQuestionStillDecodes() throws {
        let old = try JSONDecoder().decode(SecretaryReviewQueue.Question.self,
                                           from: Data(#"{"number":2,"text":"Когда?","sources":["S1"]}"#.utf8))
        XCTAssertEqual(old, .init(number: 2, text: "Когда?", sources: ["S1"]))
    }

    func testNewItemKeepsAValidOptionListAndFlattensEverythingElse() {
        let structured = SecretaryReviewQueue.item(number: 9, question: "Оставить абзац?\n- a) Да\n  - минус: длинно\n- b) Нет\n- Рекомендую: a")
        XCTAssertEqual(structured, "- Q9. Оставить абзац?\n  - a) Да\n    - минус: длинно\n  - b) Нет\n  - Рекомендую: a")
        let read = SecretaryReviewQueue.openQuestions(in: "## Открытые вопросы\n\n\(structured)\n")
        XCTAssertEqual(read.first?.options?.map(\.key), ["a", "b"])
        XCTAssertEqual(read.first?.options?.first?.cons, ["длинно"])
        XCTAssertEqual(read.first?.recommend, "a")
        XCTAssertNil(read.first?.why)
        XCTAssertEqual(SecretaryReviewQueue.item(number: 9, question: "Первая строка\nвторая"), "- Q9. Первая строка вторая")
        XCTAssertEqual(SecretaryReviewQueue.item(number: 9, question: "Что выбрать?\n- просто пункт"), "- Q9. Что выбрать? - просто пункт")
    }
}
