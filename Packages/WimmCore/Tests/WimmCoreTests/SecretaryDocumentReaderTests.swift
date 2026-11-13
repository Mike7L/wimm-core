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
        XCTAssertEqual(read, section.blocks)
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
}
