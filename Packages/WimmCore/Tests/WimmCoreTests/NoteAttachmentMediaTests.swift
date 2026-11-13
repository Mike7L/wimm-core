import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure

/// Evernote imports keep their audio, photos and PDFs as attachments of a
/// `.txt` note; these tests pin how they are found and written back.
final class NoteAttachmentMediaTests: XCTestCase {
    private var dir: URL!
    private var note: URL!
    private var audio: URL!
    private var photo: URL!
    private let audioID = UUID()
    private let photoID = UUID()
    private let svgID = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-media-\(UUID().uuidString)")
        let attachments = dir.appendingPathComponent("Attachments/Evernote/A861814C", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        note = dir.appendingPathComponent("Wimm_2019-04-09_19-04-15_a861814c.txt")
        // Evernote names carry colons; the sidecar stores them percent-escaped.
        audio = attachments.appendingPathComponent("Evernote_20190409_19:04:22.m4a")
        photo = attachments.appendingPathComponent("Evernote_Snapshot.jpg")
        for file in [note!, audio!, photo!] { try Data([1]).write(to: file) }
        try writeSidecar([
            "importSource": "Evernote",
            "keepMe": ["nested": true],
            "attachments": [
                ["id": audioID.uuidString, "type": "audio", "url": audio.absoluteString,
                 "extractedText": "Бабушка про балет", "extractionProvider": "gemini", "custom": 1],
                ["id": photoID.uuidString, "type": "image", "url": photo.absoluteString],
                ["id": svgID.uuidString, "type": "image",
                 "url": attachments.appendingPathComponent("drawing.svg").absoluteString],
                ["id": UUID().uuidString, "type": "audio",
                 "url": attachments.appendingPathComponent("Evernote_20190409_19:04:22_micro.m4a").absoluteString],
            ],
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var sidecarURL: URL { FileStore.metadataURL(forRecordingURL: note) }

    private func writeSidecar(_ dict: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]).write(to: sidecarURL)
    }

    private func readSidecar() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
    }

    private func entry(_ id: UUID) throws -> [String: Any] {
        let list = try XCTUnwrap(readSidecar()["attachments"] as? [[String: Any]])
        return try XCTUnwrap(list.first { $0["id"] as? String == id.uuidString })
    }

    func testFindsAudioAndPhotoAttachmentsOfATextNote() {
        let items = NoteAttachmentMedia.items(ofNote: note)
        XCTAssertEqual(items.count, 4)
        let audioItems = NoteAttachmentMedia.audio(ofNote: note)
        XCTAssertEqual(audioItems.map(\.id), [audioID], "derived _micro copies and missing files are not audio to retranscribe")
        XCTAssertEqual(audioItems.first?.url.lastPathComponent, "Evernote_20190409_19:04:22.m4a")
        XCTAssertEqual(audioItems.first?.text, "Бабушка про балет")
        XCTAssertTrue(items.first { $0.id == photoID }!.isImage)
        XCTAssertFalse(items.first { $0.id == photoID }!.wasExtracted)
        XCTAssertFalse(items.first { $0.id == svgID }!.isImage, "SVG is drawn, not something to OCR")
    }

    func testResolvesRelativeAndAbsolutePaths() {
        XCTAssertEqual(NoteAttachmentMedia.resolve("/tmp/a.m4a")?.path, "/tmp/a.m4a")
        XCTAssertEqual(NoteAttachmentMedia.resolve(audio.absoluteString), audio.standardizedFileURL)
        XCTAssertTrue(NoteAttachmentMedia.resolve("Attachments/Evernote/x.jpg")?.path.hasSuffix("/Attachments/Evernote/x.jpg") == true)
        XCTAssertNil(NoteAttachmentMedia.resolve("https://example.com/a.jpg"))
        XCTAssertNil(NoteAttachmentMedia.resolve(""))
    }

    func testNewTranscriptReplacesTheAttachmentTextInPlace() throws {
        let result = try NoteAttachmentMedia.setText(
            "  Новый текст  ", provider: "parakeet", model: "parakeet:ultra", attachmentID: audioID, ofNote: note)
        XCTAssertEqual(result, .written)
        let updated = try entry(audioID)
        XCTAssertEqual(updated["extractedText"] as? String, "Новый текст")
        XCTAssertEqual(updated["extractionProvider"] as? String, "parakeet")
        XCTAssertEqual(updated["extractionModel"] as? String, "parakeet:ultra")
        XCTAssertEqual(updated["custom"] as? Int, 1, "unknown keys of the entry survive")
        let previousRuns = try XCTUnwrap(updated["previousRuns"] as? [[String: Any]])
        XCTAssertEqual(previousRuns.count, 1)
        XCTAssertEqual(previousRuns.first?["text"] as? String, "Бабушка про балет")
        XCTAssertEqual(previousRuns.first?["provider"] as? String, "gemini")
        let item = try XCTUnwrap(NoteAttachmentMedia.items(ofNote: note).first { $0.id == audioID })
        XCTAssertEqual(item.previousRuns.map(\.text), ["Бабушка про балет"])
        XCTAssertEqual(item.previousRuns.map(\.provider), ["gemini"])
        XCTAssertNotNil(try readSidecar()["keepMe"], "the rest of the sidecar survives")
        XCTAssertEqual(try entry(photoID)["url"] as? String, photo.absoluteString)
    }

    func testNewOCRArchivesPreviousOCRInsteadOfOverwriting() async throws {
        _ = try NoteAttachmentMedia.setText(
            "Счёт 2400 EUR", provider: "vision", model: "VNRecognizeText",
            attachmentID: photoID, ofNote: note, emptyIsNoSpeech: false)
        _ = try NoteAttachmentMedia.setText(
            "# Счёт\n\n| Позиция | Сумма |\n| --- | --- |\n| Ноутбук | 2400 EUR |",
            provider: "vision", model: "RecognizeDocuments",
            attachmentID: photoID, ofNote: note, emptyIsNoSpeech: false)

        let item = try XCTUnwrap(NoteAttachmentMedia.items(ofNote: note).first { $0.id == photoID })
        XCTAssertTrue(item.text?.contains("| Позиция | Сумма |") == true)
        XCTAssertEqual(item.previousRuns.count, 1)
        XCTAssertEqual(item.previousRuns.first?.text, "Счёт 2400 EUR")
        XCTAssertEqual(item.previousRuns.first?.provider, "vision")
        XCTAssertEqual(item.previousRuns.first?.model, "VNRecognizeText")

        // Also check AttachmentRepository.saveOCR on a main image note archives previous OCR & document runs.
        let imageNote = dir.appendingPathComponent("scan.png")
        try Data([1]).write(to: imageNote)
        let repo = AttachmentRepository(metadataRepository: MetadataRepository())
        await repo.saveOCR(
            for: imageNote, text: "First OCR text", provider: "vision",
            model: "VNRecognizeText", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        await repo.saveOCR(
            for: imageNote, text: "# Formatted OCR\n\nSecond OCR text", provider: "gemini",
            model: "gemini-3-flash-preview", startedAt: Date(timeIntervalSince1970: 1_700_000_100))

        let variants = NoteTranscriptVariant.variants(forNoteFile: imageNote)
        XCTAssertEqual(variants.map(\.text), [
            "First OCR text",
            "# Formatted OCR\n\nSecond OCR text",
        ])
        XCTAssertEqual(variants.map(\.kind), [.local, .cloud])
    }

    func testNoSpeechNeverReplacesAnEarlierTranscript() throws {
        for verdict in ["", NoteAttachmentMedia.noSpeechText] {
            let result = try NoteAttachmentMedia.setText(
                verdict, provider: "gemini", model: nil, attachmentID: audioID, ofNote: note)
            XCTAssertEqual(result, .keptExisting)
            XCTAssertEqual(try entry(audioID)["extractedText"] as? String, "Бабушка про балет")
        }
    }

    func testNoSpeechOnAnEmptyAttachmentIsStoredAsTheVerdict() throws {
        let result = try NoteAttachmentMedia.setText("", provider: "gemini", model: nil, attachmentID: photoID, ofNote: note)
        XCTAssertEqual(result, .written)
        XCTAssertEqual(try entry(photoID)["extractedText"] as? String, NoteAttachmentMedia.noSpeechText)
    }

    func testOCRWithoutWritingIsRememberedAsRead() throws {
        try NoteAttachmentMedia.setText(
            "", provider: "vision", model: "VNRecognizeText", attachmentID: photoID, ofNote: note, emptyIsNoSpeech: false)
        XCTAssertEqual(try entry(photoID)["extractedText"] as? String, "")
        let item = try XCTUnwrap(NoteAttachmentMedia.items(ofNote: note).first { $0.id == photoID })
        XCTAssertNil(item.text)
        XCTAssertTrue(item.wasExtracted, "a rerun must not OCR the same photo again")
        XCTAssertFalse(item.hasMeaningfulText)
    }

    func testUnknownAttachmentIsNotWritten() throws {
        let before = try Data(contentsOf: sidecarURL)
        let result = try NoteAttachmentMedia.setText("x", provider: "gemini", model: nil, attachmentID: UUID(), ofNote: note)
        XCTAssertEqual(result, .attachmentMissing)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), before)
    }

    func testQueueEntriesWrittenBeforeAttachmentsStillDecode() throws {
        let state = dir.appendingPathComponent("AgentState", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let legacy = """
        {"schema":"RetranscriptionQueue@v1","entries":[{"file":"/x/a.m4a","noteId":"N1","model":"m","analyze":true,
        "requestedAt":"2026-10-24T10:00:00Z","state":"done","outcome":"speech"}]}
        """
        try Data(legacy.utf8).write(to: state.appendingPathComponent("retranscription-queue.json"))
        let queue = RetranscriptionQueue(directory: state)
        XCTAssertEqual(queue.entries().count, 1)
        XCTAssertNil(queue.entries().first?.parentFile)

        _ = try queue.enqueue([.init(file: audio.path, noteId: "N2", model: "m", analyze: true, reason: nil,
                                     requestedAt: Date(), parentFile: note.path, attachmentID: audioID.uuidString)])
        XCTAssertEqual(queue.latest(forNote: note.path)?.file, audio.path)
        XCTAssertEqual(queue.latest(forNote: "/x/a.m4a")?.noteId, "N1")
    }
}
