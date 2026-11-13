import XCTest
@testable import WimmInfrastructure

final class PersonalDocumentTests: XCTestCase {
    func testLocalEditPreservesReferencesAnchorsAndOtherText() throws {
        let original = "# Личный документ\r\n\r\n<a id=\"work\"></a>\r\n## Работа\r\n\r\nМоя **мысль**. [S01]\r\n\r\n![Схема](../images/one.png)\r\n\r\n[S01]: ../recordings/note.meta.json\r\n"
        let doc = PersonalDocument(text: original)
        let block = try XCTUnwrap(doc.blocks.first(where: { $0.markdown.contains("Моя") }))
        XCTAssertEqual(doc.sources(in: block).map(\.id), ["S01"])
        XCTAssertEqual(doc.displayMarkdown(for: block), "Моя **мысль**.")
        XCTAssertEqual(doc.references["S01"], "../recordings/note.meta.json")
        XCTAssertEqual(doc.blocks.first(where: { $0.markdown == "## Работа" })?.anchor, "work")
        let updated = try XCTUnwrap(doc.replacing(blockID: block.id, with: "Новая мысль. [S01]"))
        XCTAssertEqual(updated, original.replacingOccurrences(of: "Моя **мысль**. [S01]", with: "Новая мысль. [S01]"))
    }

    func testFencesDoNotCreateFakeHeadingsOrReferenceDefinitions() throws {
        let doc = PersonalDocument(text: "# Title\n\n```markdown\n## Code\n\n[S01]: fake.json\n```\n\n## Real\nText")
        XCTAssertTrue(doc.references.isEmpty)
        let headings = doc.blocks.compactMap { block -> String? in
            if case .heading = block.kind { return block.markdown }; return nil
        }
        XCTAssertEqual(headings, ["# Title", "## Real"])
        XCTAssertTrue(doc.blocks.contains { $0.markdown.contains("```markdown\n## Code") })
    }

    func testSaveRejectsExternalEditEvenWithUnchangedTimestamp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let store = PersonalDocumentStore(url: url)
        let snapshot = try await store.load()
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try "Secretary update".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        do {
            try await store.save("Owner edit", expecting: snapshot.text)
            XCTFail("A stale draft must not overwrite the secretary")
        } catch PersonalDocumentError.changedOnDisk {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Secretary update")
    }

    func testRepeatedAutosaveUsesLastSavedRevision() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let store = PersonalDocumentStore(url: url)
        try await store.save("First", expecting: "Original")
        try await store.save("Second", expecting: "First")
        let loaded = try await store.load()
        XCTAssertEqual(loaded.text, "Second")
    }
}
