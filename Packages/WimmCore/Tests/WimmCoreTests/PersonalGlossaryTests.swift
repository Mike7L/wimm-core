import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class PersonalGlossaryTests: XCTestCase {
    func testSnapshotsSurviveEditingDisablingAndDeletion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalGlossaryStore(directory: folder)
        var document = try await store.read()
        document.includeBundledTerms = false
        document.terms = [.init(canonical: "Люмен", context: "Название моего проекта", observedForms: ["люмин"])]
        document = try await store.save(document)
        let firstValue = try await store.snapshot(bundled: .production)
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.protocolVersion, "context-v4-personal")
        let again = try await store.snapshot(bundled: .production)
        XCTAssertEqual(first.sha256, again?.sha256)
        XCTAssertEqual(first.entries.map(\.canonical), ["Люмен"])
        let json = try LLMJSONClient.noteCardInputJSON(noteId: "test", transcript: "Открой люмин", localHypothesis: nil, lang: "ru", glossary: first)
        XCTAssertTrue(json.contains("Люмен"))
        document.terms[0].context = "Новый контекст"
        document = try await store.save(document)
        let second = try await store.snapshot(bundled: nil)
        XCTAssertNotEqual(first.sha256, second?.sha256)
        document.terms[0].isEnabled = false
        document = try await store.save(document)
        let disabled = try await store.snapshot(bundled: .production)
        XCTAssertNil(disabled)
        document.terms = []
        _ = try await store.save(document)
        let replay = try await store.snapshot(sha256: first.sha256)
        XCTAssertEqual(replay.entries.first?.description, "Название моего проекта")
    }

    func testStaleWriterAndInvalidEntriesCannotOverwrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = PersonalGlossaryStore(directory: folder)
        let second = PersonalGlossaryStore(directory: folder)
        var document = try await first.read()
        let stale = document
        document.terms = [.init(canonical: "Name", context: "Customer")]
        document = try await first.save(document)
        do { _ = try await second.save(stale); XCTFail("Must reject stale revision") }
        catch PersonalGlossaryStore.StoreError.stale { }
        document.terms.append(.init(canonical: "name", context: "Duplicate"))
        do { _ = try await first.save(document); XCTFail("Must reject duplicate") }
        catch PersonalGlossaryStore.StoreError.invalid { }
        let retained = try await second.read()
        XCTAssertEqual(retained.terms.count, 1)
    }

    func testProcessorReloadsVocabularyBetweenCallsAndClearsOldReceipt() async throws {
        setenv("WIMM_TEST_MODE", "SUCCESS", 1)
        defer { unsetenv("WIMM_TEST_MODE") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalGlossaryStore(directory: folder.appendingPathComponent("Glossary"))
        var document = PersonalGlossaryDocument()
        document.includeBundledTerms = false
        document.terms = [.init(canonical: "Name", context: "Customer")]
        document = try await store.save(document)
        let file = folder.appendingPathComponent("note.txt")
        try Data("source".utf8).write(to: file)
        let metadata = MetadataRepository()
        let processor = NoteProcessor(metadataRepository: metadata, personalGlossaryStore: store)
        _ = try await processor.makeNoteCard(file: file, transcript: "Customer")
        let before = await metadata.metadata(for: file)
        XCTAssertNotNil(before["analysisGlossary"] as? [String: Any])
        document.terms[0].isEnabled = false
        _ = try await store.save(document)
        _ = try await processor.makeNoteCard(file: file, transcript: "Customer")
        let after = await metadata.metadata(for: file)
        XCTAssertNil(after["analysisGlossary"] as? [String: Any])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "source")
    }

    func testCorruptVocabularyIsNotOverwritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("personal.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        let store = PersonalGlossaryStore(directory: folder)
        do { _ = try await store.save(.init()); XCTFail("Must reject corrupt vocabulary") }
        catch is DecodingError { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testKindAndSensitiveAreOptionalAndBackwardCompatible() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","canonical":"Люмен","context":"Проект","observedForms":[],"isEnabled":true,"confirmedAt":0}"#
        let term = try JSONDecoder().decode(PersonalGlossaryTerm.self, from: Data(old.utf8))
        XCTAssertNil(term.kind)
        XCTAssertFalse(term.sensitive)
        let reencoded = String(decoding: try JSONEncoder().encode(term), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("kind"))
        XCTAssertFalse(reencoded.contains("sensitive"))
        let newer = old.replacingOccurrences(of: #""confirmedAt":0"#, with: #""confirmedAt":0,"kind":"pet","sensitive":true"#)
        let future = try JSONDecoder().decode(PersonalGlossaryTerm.self, from: Data(newer.utf8))
        XCTAssertEqual(future.kind, .other, "an unknown kind must not make the file unreadable")
        XCTAssertTrue(future.sensitive)
    }

    func testPrivateModeWithholdsSensitiveTermsButMasksThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalGlossaryStore(directory: folder)
        var document = try await store.read()
        document.includeBundledTerms = false
        document.terms = [
            .init(canonical: "Люмен", context: "Название моего проекта", observedForms: ["люмин"]),
            .init(canonical: "Маша", context: "Сестра", observedForms: ["Маши"], kind: .person, sensitive: true),
            .init(canonical: "Акме", context: "Бывший работодатель", isEnabled: false, kind: .org, sensitive: true),
        ]
        document = try await store.save(document)
        let stored = try await store.read()
        XCTAssertEqual(stored.terms.filter(\.sensitive).count, 2)

        let open = try await store.analysisVocabulary(bundled: nil, privateMode: false)
        XCTAssertEqual(Set(open.glossary?.entries.map(\.canonical) ?? []), ["Люмен", "Маша"])
        let closed = try await store.analysisVocabulary(bundled: nil, privateMode: true)
        XCTAssertEqual(closed.glossary?.entries.map(\.canonical), ["Люмен"])
        XCTAssertEqual(Set(closed.pseudonymDictionary.map(\.canonical)), ["Маша", "Акме"])
        XCTAssertEqual(closed.pseudonymDictionary.first { $0.canonical == "Маша" }?.kind, .person)
        // The private artifact is archived, so its receipt can be replayed.
        let sha = try XCTUnwrap(closed.glossary?.sha256)
        let replay = try await store.snapshot(sha256: sha)
        XCTAssertEqual(replay.entries.map(\.canonical), ["Люмен"])
        let json = try LLMJSONClient.noteCardInputJSON(noteId: "t", transcript: "x", localHypothesis: nil, lang: "ru", glossary: closed.glossary)
        XCTAssertFalse(json.contains("Маша"))
    }
}
