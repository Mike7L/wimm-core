import XCTest
import WimmInfrastructure
@testable import WimmStudio

final class StudioInboxTests: XCTestCase {
    func testDiffFindsAddedEditedAndRemovedParagraphs() {
        let baseline = """
        # Doc

        ## Работа

        Пётр работал в кафе на Рюгене до конца сезона.

        Старый абзац, который потом убрали целиком.

        ## Семья

        Мама живёт в Бремене.
        """
        let current = PersonalDocument(text: """
        # Doc

        ## Работа

        Пётр работал в кафе на Рюгене до конца октября 2026.

        ## Семья

        Мама живёт в Бремене.

        Новый абзац про бабушку и её подвал.
        """)
        let diff = StudioInbox.diff(baseline: baseline, current: current)
        XCTAssertEqual(diff.changes.map(\.kind), [.edited, .added])
        XCTAssertEqual(diff.changes.first?.section, "Работа")
        XCTAssertTrue(diff.changes.first?.previous?.contains("до конца сезона") == true)
        XCTAssertEqual(diff.changes.last?.section, "Семья")
        XCTAssertEqual(diff.removals.count, 1)
        XCTAssertEqual(diff.removals.first?.section, "Работа")
        let heading = current.blocks.first { StudioInbox.title($0) == "Работа" }?.id
        XCTAssertEqual(diff.removals.first?.nearBlockID, heading)

        let ancestors = StudioInbox.ancestorHeadings(of: diff.changes.map(\.blockID), in: current)
        let titles = Set(current.blocks.filter { ancestors.contains($0.id) }.map(StudioInbox.title))
        XCTAssertEqual(titles, ["Doc", "Работа", "Семья"])
    }

    func testMovedParagraphIsNotAChange() {
        let baseline = "## A\n\nПервый.\n\n## B\n\nВторой.\n"
        let current = PersonalDocument(text: "## B\n\nВторой.\n\n## A\n\nПервый.\n")
        XCTAssertEqual(StudioInbox.diff(baseline: baseline, current: current), .empty)
    }

    func testOpenQuestionsComeFromTheOpenSectionOnly() {
        let queue = """
        # Очередь

        ## Открытые вопросы

        - Q36. Сохранять ли ответ ChatGPT (S4695, S5677)?


        - Q31. Q31. Кто участвует в записи S7189?

        Порядок — по срочности.

        - **Q1. Finanzamt.** Есть ли доступ к ELSTER? [S1001] [W40]

        ## Разрешено

        - Q22. Закрыто.
        """
        let questions = StudioInbox.openQuestions(in: queue)
        XCTAssertEqual(questions.map(\.number), [36, 31, 1])
        XCTAssertEqual(questions[0].sources, ["S4695", "S5677"])
        XCTAssertEqual(questions[1].text, "Кто участвует в записи S7189?")
        XCTAssertEqual(questions[2].text, "Finanzamt. Есть ли доступ к ELSTER? [S1001] [W40]")
        XCTAssertEqual(questions[2].sources, ["S1001"])
    }

    func testQuestionsRequireOneUnambiguousParagraphOutsideDiscussion() throws {
        let document = PersonalDocument(text: """
        # Документ

        ## Машина

        Регистрацию сняли в августе. [S1] [S2]

        Машина стояла у дома. [S3]

        Машина была застрахована. [S3]

        ## Вопросы и наблюдения для обсуждения

        - Что произошло? [S1] [S4]

        [S1]: first.meta.json
        [S2]: second.meta.json
        [S3]: third.meta.json
        [S4]: fourth.meta.json
        """)
        let index = StudioInbox.questionSourceBlocks(in: document)
        let expected = try XCTUnwrap(document.blocks.first { $0.markdown.hasPrefix("Регистрацию") })
        let questions = StudioInbox.openQuestions(in: """
        ## Открытые вопросы
        - Q1. Что произошло? [S1] [S2]
        - Q2. Где она стояла? [S3]
        - Q3. Кто знает? [S4]
        - Q4. Что с машиной? [S1] [S3]
        """)
        XCTAssertEqual(questions.reversed().map { StudioInbox.questionBlock($0, sourceBlocks: index) },
                       [expected.id, nil, nil, nil])
    }

    func testQuestionMarkerPlacesTheQuestionAndIsNotAChange() throws {
        let before = "# Документ\n\n## Работа\n\nПодал анкету в клуб. [S1] **[?2]**\n\nЗадание отправил. [S1]\n\n[S1]: a.meta.json\n"
        let after = before.replacingOccurrences(of: "**[?2]**", with: "**[Q64]**")
        let document = PersonalDocument(text: after)
        XCTAssertEqual(StudioInbox.diff(baseline: before, current: document), .empty)
        let marked = try XCTUnwrap(document.blocks.first { $0.markdown.hasPrefix("Подал") })
        let question = StudioInbox.Question(number: 64, text: "В клуб приняли?", sources: [])
        XCTAssertEqual(StudioInbox.questionBlock(question, sourceBlocks: [:], markerBlocks: StudioInbox.questionMarkerBlocks(in: document)), marked.id)
        XCTAssertNil(StudioInbox.questionBlock(question, sourceBlocks: [:]))
    }

    func testAnswerArchiveRoundTripsAndLoadsOlderInboxState() throws {
        let data = Data(#"{"seenBlocks":[],"questionsSeen":[2]}"#.utf8)
        var state = try JSONDecoder().decode(StudioInboxSeen.self, from: data)
        XCTAssertEqual(state.questionsSeen, [2])
        XCTAssertNil(state.answers)

        state.answers = [2: .init(question: .init(number: 2, text: "Когда?", sources: ["S1"]), text: "В августе.")]
        XCTAssertEqual(try JSONDecoder().decode(StudioInboxSeen.self, from: JSONEncoder().encode(state)), state)
    }

    func testPassesAreNewestFirstWithProseSummary() {
        let log = """
        # Журнал

        2026-10-31T18:42:17+01:00 · 20261031-184217-1f66 · packet · S7209, S4878 · Задач: 1.

        2026-11-02 · ручной проход · S7240–S7266 · Внесено: отпуск, жильё.
        """
        let passes = StudioInbox.passes(in: log)
        XCTAssertEqual(passes.count, 2)
        XCTAssertEqual(passes[0].label, "ручной проход")
        XCTAssertEqual(passes[0].summary, "Внесено: отпуск, жильё.")
        XCTAssertNil(passes[0].runID)
        XCTAssertEqual(passes[1].runID, "20261031-184217-1f66")
        XCTAssertEqual(passes[1].date, "2026-10-31 18:42")
    }

    func testBackupNamesCarryTheRunStart() {
        let date = StudioInbox.backupDate("me_structured.2026-11-01-221705-before-secretary.md")
        let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: date!)
        XCTAssertEqual([parts.day, parts.hour, parts.minute], [1, 22, 17])
        XCTAssertNotNil(StudioInbox.backupDate("me_structured.md.20261030-manual-codex-1743-before-secretary"))
    }
}
