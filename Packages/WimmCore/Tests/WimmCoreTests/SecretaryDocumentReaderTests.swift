import XCTest
@testable import WimmSecretary

final class SecretaryDocumentReaderTests: XCTestCase {
    private let document = """
    # Личный документ

    Вступление.

    ## Работа

    Сезон на Рюгене закончился 23 октября. [S1]

    ### Поиск работы

    Резюме в июле.

    ## Семья

    Варвара любит балет.

    ### Без установленной даты

    Поход в театр.

    ## Отец

    ### Без установленной даты

    Разговор про деньги.

    [S1]: recordings/a.m4a
    """

    func testExactBlocksShareSectionIDsAndExcludeCitationDefinitions() {
        let section = SecretaryDocumentReader.section(document: document, query: "Работа")
        let ids = section.blocks.map(\.id)
        let read = SecretaryDocumentReader.blocks(document: document, ids: ids + ["b999999"])
        XCTAssertEqual(read.map(\.id), section.blocks.map(\.id))
        XCTAssertEqual(read.map(\.text), section.blocks.map(\.text))
        XCTAssertEqual(read.last?.path, "# Личный документ › ## Работа › ### Поиск работы",
                       "a block read by ID carries the headings above it")
        XCTAssertNil(section.blocks.last?.path, "a section read already carries its heading")
        XCTAssertFalse(SecretaryDocumentReader.blocks(document: document, ids: (1...100).map { "b\($0)" })
            .contains { $0.text.hasPrefix("[S1]:") })
    }

    func testOutlineListsHeadingsWithSubtreeBytes() {
        let outline = SecretaryDocumentReader.outline(document: document)
        XCTAssertEqual(outline.map(\.title), ["# Личный документ", "## Работа", "### Поиск работы", "## Семья",
                                              "### Без установленной даты", "## Отец", "### Без установленной даты"])
        let work = outline[1], search = outline[2]
        XCTAssertEqual(work.depth, 2)
        XCTAssertGreaterThan(work.bytes, search.bytes, "a section's size includes its subsections")
    }

    func testSectionIncludesSubsectionsAndSkipsDefinitions() {
        let read = SecretaryDocumentReader.section(document: document, query: "Работа")
        XCTAssertEqual(read.status, "complete")
        let text = read.blocks.map(\.text).joined()
        XCTAssertTrue(text.contains("Сезон на Рюгене"))
        XCTAssertTrue(text.contains("Резюме в июле"))
        XCTAssertFalse(text.contains("Варвара"))

        let last = SecretaryDocumentReader.section(document: document, query: "## Отец")
        XCTAssertFalse(last.blocks.map(\.text).joined().contains("recordings/a.m4a"))
    }

    func testRepeatedTitleIsAmbiguousButBlockIDIsExact() {
        let read = SecretaryDocumentReader.section(document: document, query: "Без установленной даты")
        XCTAssertEqual(read.status, "ambiguous")
        XCTAssertEqual(read.matches.count, 2)

        let exact = SecretaryDocumentReader.section(document: document, query: read.matches[1].id)
        XCTAssertEqual(exact.status, "complete")
        XCTAssertTrue(exact.blocks.map(\.text).joined().contains("Разговор про деньги"))
    }

    func testSectionPagesByWholeBlocks() {
        let first = SecretaryDocumentReader.section(document: document, query: "Работа", byteLimit: 1)
        XCTAssertEqual(first.status, "partial")
        XCTAssertEqual(first.blocks.count, 1, "a page holds at least one block")
        let rest = SecretaryDocumentReader.section(document: document, query: "Работа", offset: first.nextOffset!, byteLimit: 100_000)
        XCTAssertEqual(rest.status, "complete")
        XCTAssertEqual(first.blocks.count + rest.blocks.count, first.totalBlocks)
    }

    func testUnknownSectionSuggestsContainingTitles() {
        let read = SecretaryDocumentReader.section(document: document, query: "поиск")
        XCTAssertEqual(read.status, "not_found")
        XCTAssertEqual(read.matches.map(\.title), ["### Поиск работы"])
    }

    func testFindReturnsMatchingBlocks() {
        let read = SecretaryDocumentReader.find(document: document, query: "балет")
        XCTAssertTrue(read.blocks.map(\.text).joined().contains("Варвара любит балет"))
        XCTAssertFalse(read.blocks.map(\.text).joined().contains("recordings/a.m4a"))
    }

    func testFoundBlockCarriesHeadingPath() {
        let diary = """
        ## Деньги

        ### С Варварой

        **10 августа.** Остаток 300 €.
        """
        let found = SecretaryDocumentReader.find(document: diary, query: "остаток").blocks
        let entry = found.first { $0.text.contains("Остаток") }
        XCTAssertEqual(entry?.section, "### С Варварой")
        XCTAssertEqual(entry?.path, "## Деньги › ### С Варварой")
        XCTAssertEqual(found.first { $0.text.hasPrefix("## Деньги") }?.path, nil, "a top heading has nothing above it")
    }

    /// A byte budget for one entry and its heading (headings here are under 40 bytes):
    /// which entry wins decides what an agent sees.
    private func winner(_ document: String, _ query: String, among candidates: [String]) -> String? {
        let budget = 40 + candidates.map(\.utf8.count).max()!
        let text = SecretaryDocumentReader.find(document: document, query: query, byteLimit: budget).blocks.map(\.text).joined()
        let won = candidates.filter { text.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return won.count == 1 ? won[0] : nil
    }

    func testRareWordOutranksCommonWordAtEqualCount() {
        let common = ["Киоск открыт утром.", "Киоск закрыт днём.", "Киоск пустой вечером."]
        let rare = "Паром ушёл в шесть."
        let document = "## Остров\n\n" + (common + [rare]).map { $0 + "\n\n" }.joined()
        XCTAssertEqual(winner(document, "киоск паром", among: common + [rare]), rare,
                       "both match one query word; the word in one entry tells more than the word in three")
    }

    func testThreeLetterWordCountsAsWholeWord() {
        let plain = "Киоск: открыт вечером."
        let cto = "Киоск: был там CTO."
        XCTAssertEqual(winner("## Остров\n\n\(plain)\n\n\(cto)\n\n", "киоск cto", among: [plain, cto]), cto,
                       "a three-letter word is not a term, but it still tells the entries apart")
        let longer = "Киоск: играл в баре."
        let bar = "Киоск: зашёл в бар."
        XCTAssertEqual(winner("## Остров\n\n\(longer)\n\n\(bar)\n\n", "киоск бар", among: [longer, bar]), bar,
                       "«бар» matches as a whole word, not as the start of «баре»")
    }

    func testHeadingWordsAboveEntryBreakTies() {
        let anton = "**Июль.** Остаток 50 €."
        let varvara = "**Август.** Остаток 300 €."
        let document = """
        ## Остров

        ### С Антоном

        \(anton)

        ### С Варварой

        \(varvara)
        """
        XCTAssertEqual(winner(document, "варвара остаток", among: [anton, varvara]), varvara,
                       "the person is named only in the heading above the entry")
    }
}
