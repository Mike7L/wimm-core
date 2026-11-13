import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class PrivateEgressPreviewTests: XCTestCase {
    func testTextPreviewUsesSensitiveVocabularyForBothHypothesesWithoutWriting() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersonalGlossaryStore(directory: base.appendingPathComponent("Glossary"))
        var document = try await store.read()
        document.terms = [
            .init(canonical: "Маша", context: "Test person", kind: .person, sensitive: true),
            .init(canonical: "Акме", context: "Test organization", kind: .org, sensitive: true),
            .init(canonical: "ТестовыйТермин", context: "Public test vocabulary", kind: .other, sensitive: false),
        ]
        _ = try await store.save(document)
        let before = try files(in: base)
        let preview = try await NoteProcessor(personalGlossaryStore: store).privateEgressPreview(
            text: "Маша пишет в Акме: test@example.org", localTranscript: "Маша пишет в Акме")

        XCTAssertTrue(preview.wouldSend)
        XCTAssertEqual(preview.dictionaryTerms, 2)
        for secret in ["Маша", "Акме", "example.org"] {
            XCTAssertFalse(preview.maskedUser.contains(secret))
        }
        let person = try XCTUnwrap(preview.legend.first { $0.kind == .person })
        XCTAssertEqual(preview.maskedNoteText.components(separatedBy: "⟦\(person.id)⟧").count - 1, 2)
        XCTAssertTrue(preview.readableNoteText.contains("— local hypothesis —"))
        XCTAssertEqual(try files(in: base), before, "preview must not archive glossary snapshots or maps")
    }

    func testPreviewDoesNotCreateAnAbsentGlossaryDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersonalGlossaryStore(directory: base)
        let client = LLMJSONClient(model: "unused", tracer: nil, personalGlossaryStore: store)
        let preview = try await client.previewPrivateEgress(noteId: "synthetic", transcript: "test@example.org", lang: nil)
        XCTAssertTrue(preview.wouldSend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    func testFilePreviewMasksBodyAndAttachmentsAndKeepsFramingOnlyInPayload() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = base.appendingPathComponent("synthetic.txt")
        try "Write to body@example.org".write(to: note, atomically: true, encoding: .utf8)
        let attachment = NoteAttachment(url: base.appendingPathComponent("scan.pdf"), type: "pdf",
                                        extractedText: "Attachment contact: attachment@example.org")
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) {
            $0["attachments"] = [["id": attachment.id.uuidString, "url": attachment.url.absoluteString,
                                   "type": attachment.type, "ocrText": attachment.extractedText!]]
            return true
        }
        let before = try files(in: base)
        let preview = try await NoteProcessor(personalGlossaryStore: nil).privateEgressPreview(file: note)
        XCTAssertTrue(preview.wouldSend)
        XCTAssertTrue(preview.maskedNoteText.hasPrefix("[MAIN_TEXT"))
        XCTAssertTrue(preview.readableNoteText.hasPrefix("Write to ⟦E"))
        XCTAssertTrue(preview.readableNoteText.contains("[ATTACHMENT_1_OCR"))
        XCTAssertFalse(preview.maskedUser.contains("example.org"))
        XCTAssertEqual(preview.legend.filter { $0.kind == .email }.count, 2)
        XCTAssertEqual(try files(in: base), before)
    }

    func testEmptyTextThrowsAndAmbiguousPlaceholdersRefuseWithoutRawFallback() async throws {
        let processor = NoteProcessor(personalGlossaryStore: nil)
        do {
            _ = try await processor.privateEgressPreview(text: " \n ")
            XCTFail("empty input must fail")
        } catch ProcessingError.emptyContent {}
        let refused = try await processor.privateEgressPreview(text: "secret@example.org ⟦P1⟧")
        XCTAssertFalse(refused.wouldSend)
        XCTAssertNotNil(refused.refusal)
        XCTAssertEqual(refused.readableNoteText, "")
        XCTAssertEqual(refused.maskedUser, "")
    }

    private func files(in base: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.path] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
