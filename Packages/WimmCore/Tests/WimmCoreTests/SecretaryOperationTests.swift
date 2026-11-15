import Foundation
import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryOperationTests: XCTestCase {
    private func packet(_ text: String) throws -> SecretaryPacket {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("docs/me.md")
        let workspace = try XCTUnwrap(SecretaryWorkspace(document: document))
        let task = SecretaryTask(id: "operations", kind: .pass, workspace: workspace, threads: [], wimmCLI: "/unused", createdAt: Date(), packetMode: true)
        return SecretaryPacket(task: task, documentData: Data(text.utf8), registryData: Data(), queueData: Data(),
            blocks: SecretaryPacket.blocks(text), selected: [], receipts: [], projectedSourceIDs: [], newSources: [],
            fullSourcesByID: [:], payload: [:], system: "")
    }

    func testLiteralUnicodePatchesPreserveUnchangedBytesAndRejectAmbiguity() throws {
        let p = try packet("Ёж 🦔. Repeat Repeat. e\u{301} ≠ é.\n\n")
        let id = p.blocks[0].id
        let edits = try p.materializedEdits([
            .init(block: id, text: "Сова 🦉", operation: "replace_text", match: "Ёж 🦔"),
            .init(block: id, text: "Next.\n\n", operation: "insert_after")], allowed: [id])
        XCTAssertEqual(edits[0].text, "Сова 🦉. Repeat Repeat. e\u{301} ≠ é.\n\nNext.\n\n")
        let overlapping = try packet("aaa\n\n")
        XCTAssertThrowsError(try overlapping.materializedEdits([.init(block: overlapping.blocks[0].id, text: "X", operation: "replace_text", match: "aa")], allowed: [overlapping.blocks[0].id]))
        for match in ["Repeat", "absent", ""] {
            XCTAssertThrowsError(try p.materializedEdits([.init(block: id, text: "X", operation: "replace_text", match: match)], allowed: [id]))
        }
        XCTAssertThrowsError(try p.materializedEdits([
            .init(block: id, text: "X", operation: "replace_text", match: "Ёж 🦔"),
            .init(block: id, text: "Y", operation: "replace_text", match: "🦔")], allowed: [id]))
        XCTAssertThrowsError(try p.materializedEdits([.init(block: id, text: "X", operation: "unknown")], allowed: [id]))
    }

    func testPrimaryRoutingDoesNotLetBackgroundScreenWordsReplaceTheRelevantTopic() {
        let text = "# Document\n\nIntro.\n\n### Employment\n\n" + String(repeating: "Career salary contract.\n\n", count: 30) + "### Wimm\n\nRecording and transcription status.\n\n"
        let blocks = SecretaryPacket.blocks(text)
        let context = SecretaryPacket.editorContext(blocks: blocks, sourceIDs: [], primaryText: "Wimm recording transcription", limit: 2000)
        XCTAssertTrue(context.blocks.contains { $0.text.contains("Recording and transcription status") })
        XCTAssertNotNil(context.report["sections"])
    }

    /// A later note about the same dish uses other word forms than the document's entry; the
    /// entry must still be routed into the packet so the editor can see the contradiction.
    func testRoutingMatchesInflectedWordsSoAnEarlierEntryOnTheSameTopicIsShown() {
        let names = ["Ольга": "Ольгой", "Пётр": "Петром", "Вера": "Верой", "Глеб": "Глебом", "Зоя": "Зоей", "Тимур": "Тимуром"]
        var text = "# Документ\n\nВступление.\n\n## Люди\n\nО людях.\n\n## Быт\n\nО быте.\n\n"
        for (title, form) in names.sorted(by: { $0.key < $1.key }) { text += "### \(title)\n\nС \(form) гуляли у реки [S1].\n\n" }
        text += "### Еда\n\n- **Пирожки** (3 марта): тесто на дрожжах, 40 штук [S10].\n\n"
        let blocks = SecretaryPacket.blocks(text)
        let source = "Обсуждали праздник с Ольгой, Петром, Верой, Глебом, Зоей и Тимуром. Пирожков около 50, теста замешу без дрожжей, на разрыхлителе."
        let context = SecretaryPacket.editorContext(blocks: blocks, sourceIDs: ["S20"], primaryText: source, limit: 4000)
        let sections = (context.report["sections"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        XCTAssertTrue(sections.contains("### Еда"), "\(sections)")
        XCTAssertTrue(context.blocks.contains { $0.text.contains("тесто на дрожжах") })
    }

    func testBlockInsertionsKeepAdjacentParagraphsHeadingsAndCitationsSeparate() throws {
        for operation in ["insert_before", "insert_after"] {
            for insertion in ["Новый абзац [S3].", "Новый абзац [S3].\n", "Новый абзац [S3].\n\n"] {
                let p = try packet("До [S1].\n\n## Раздел\n\nПосле [S2].\n\n")
                let anchor = p.blocks[1]
                let edits = try p.materializedEdits([.init(block: anchor.id, text: insertion, operation: operation)], allowed: [anchor.id])
                var parts = p.blocks.map(\.text); parts[1] = edits[0].text
                let updated = parts.joined()
                let expected = operation == "insert_before"
                    ? "До [S1].\n\nНовый абзац [S3].\n\n## Раздел\n\nПосле [S2].\n\n"
                    : "До [S1].\n\n## Раздел\n\nНовый абзац [S3].\n\nПосле [S2].\n\n"
                XCTAssertEqual(updated, expected)
                XCTAssertEqual(SecretaryPacket.blocks(updated).compactMap { SecretaryPacket.heading($0.text)?.line }, ["## Раздел"])
                XCTAssertTrue(updated.contains("До [S1].")); XCTAssertTrue(updated.contains("После [S2]."))
            }
        }
    }

    func testInsertionAtUnterminatedEndPreservesIndentationAndExistingSeparators() throws {
        for ending in ["", "\n", "\n\n", "\n \t\n"] {
            let p = try packet("Исходный текст [S1]." + ending)
            let id = p.blocks[0].id
            let inserted = "    code [S2]\n\n"
            let edits = try p.materializedEdits([.init(block: id, text: inserted, operation: "insert_after")], allowed: [id])
            let missing = max(0, 2 - ending.filter { $0 == "\n" }.count)
            XCTAssertEqual(edits[0].text, "Исходный текст [S1]." + ending + String(repeating: "\n", count: missing) + inserted)
        }
        let p = try packet("Исходный текст.")
        let id = p.blocks[0].id
        let edits = try p.materializedEdits([.init(block: id, text: "\n\nНовый текст.\n\n", operation: "insert_after")], allowed: [id])
        XCTAssertEqual(edits[0].text, "Исходный текст.\n\nНовый текст.\n\n")
    }
}
