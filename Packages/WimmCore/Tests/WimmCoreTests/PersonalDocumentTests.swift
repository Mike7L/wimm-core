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

    func testReplaceBlockUpdatesTargetAndReturnsNewSHA256() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.md")
        let original = "# Личный документ\r\n\r\n<a id=\"work\"></a>\r\n## Работа\r\n\r\nМоя **мысль**. [S01]\r\n\r\n[S01]: ../recordings/note.meta.json\r\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let store = PersonalDocumentStore(url: url)
        let loaded = try await store.load()
        let block = try XCTUnwrap(loaded.blocks.first(where: { $0.markdown.contains("Моя") }))
        let newSHA = try await store.replaceBlock(
            id: block.id,
            with: "Новая мысль. [S01]",
            expectingSHA256: PersonalDocument.sha256(original),
            expectingBlockSHA256: PersonalDocument.sha256(block.markdown)
        )
        let expectedUpdated = original.replacingOccurrences(of: "Моя **мысль**. [S01]", with: "Новая мысль. [S01]")
        XCTAssertEqual(newSHA, PersonalDocument.sha256(expectedUpdated))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expectedUpdated)
    }

    func testReplaceBlockRejectsExternalEditBetweenReadAndWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.md")
        let original = "# Заголовок\n\nИсходный абзац.\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let store = PersonalDocumentStore(url: url)
        let snapshot = try await store.load()
        let block = try XCTUnwrap(snapshot.blocks.first(where: { $0.markdown.contains("Исходный") }))
        let baseSHA = PersonalDocument.sha256(snapshot.text)
        let blockSHA = PersonalDocument.sha256(block.markdown)

        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let external = "# Заголовок\n\nЧужая правка секретаря.\n"
        try external.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

        do {
            _ = try await store.replaceBlock(
                id: block.id,
                with: "Правка из веба.",
                expectingSHA256: baseSHA,
                expectingBlockSHA256: blockSHA
            )
            XCTFail("Stale SHA-256 must not overwrite an external edit")
        } catch PersonalDocumentError.changedOnDisk {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), external)
    }

    func testReplaceBlockRejectsMismatchedBlockSHA256EvenWhenFileSHA256Matches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.md")
        let onDisk = "# Заголовок\n\nТекст блока B.\n"
        try onDisk.write(to: url, atomically: true, encoding: .utf8)

        let store = PersonalDocumentStore(url: url)
        let snapshot = try await store.load()
        let block = try XCTUnwrap(snapshot.blocks.first(where: { $0.markdown == "Текст блока B." }))

        do {
            _ = try await store.replaceBlock(
                id: block.id,
                with: "Правка из веба.",
                expectingSHA256: PersonalDocument.sha256(onDisk),
                expectingBlockSHA256: PersonalDocument.sha256("Текст блока A.")
            )
            XCTFail("Mismatched block SHA-256 must refuse even when file SHA-256 and block id match")
        } catch PersonalDocumentError.changedOnDisk {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), onDisk)
    }

    func testReplaceBlockRejectsMissingBlockAndEmptyHash() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.md")
        let original = "# Заголовок\n\nАбзац.\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let store = PersonalDocumentStore(url: url)
        let baseSHA = PersonalDocument.sha256(original)
        let blockSHA = PersonalDocument.sha256("Абзац.")

        do {
            _ = try await store.replaceBlock(
                id: 999,
                with: "Другой текст",
                expectingSHA256: baseSHA,
                expectingBlockSHA256: blockSHA
            )
            XCTFail("Unknown block ID must fail")
        } catch PersonalDocumentError.blockNotFound(999) {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)

        do {
            _ = try await store.replaceBlock(
                id: 0,
                with: "Другой текст",
                expectingSHA256: "   ",
                expectingBlockSHA256: blockSHA
            )
            XCTFail("Empty expectedSHA256 must fail")
        } catch PersonalDocumentError.changedOnDisk {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)

        do {
            _ = try await store.replaceBlock(
                id: 1,
                with: "Другой текст",
                expectingSHA256: baseSHA,
                expectingBlockSHA256: "   "
            )
            XCTFail("Empty expectedBlockSHA256 must fail")
        } catch PersonalDocumentError.changedOnDisk {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }
}
