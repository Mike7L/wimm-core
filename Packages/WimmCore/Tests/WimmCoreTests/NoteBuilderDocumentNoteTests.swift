import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// Document notes (pdf/image/office) must render their extracted text and
/// never show as failed when a transcript or document.text exists on disk.
final class NoteBuilderDocumentNoteTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }

    override func tearDown() {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func buildNote(for file: URL) async -> Note {
        await NoteBuilder.build(
            file: file,
            index: 0,
            metaRepo: MetadataRepository(),
            transcriptRepo: TranscriptRepository()
        )
    }

    func testDocumentOCRUpdatesReaderAndArchivesTheReplacedText() async throws {
        let file = tempDir.appendingPathComponent("scan.pdf")
        try Data([1]).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "transcription": ["transcript": "Old body", "provider": "gemini", "model": "gemini-test"],
            "document": ["text": "Old body"],
            "title": "Keep title",
        ])
        let repository = AttachmentRepository(metadataRepository: MetadataRepository())
        await repository.saveDocumentOCR(for: file, text: " New OCR ", provider: "vision",
                                         model: "VNRecognizeText", startedAt: Date())
        let note = await buildNote(for: file)
        XCTAssertEqual(note.text, "New OCR")
        let metadata = await MetadataRepository().metadata(for: file)
        let transcription = try XCTUnwrap(metadata["transcription"] as? [String: Any])
        let previous = try XCTUnwrap(transcription["previousRuns"] as? [[String: Any]])
        XCTAssertEqual(previous.first?["transcript"] as? String, "Old body")
        XCTAssertEqual((metadata["document"] as? [String: Any])?["text"] as? String, "New OCR")
        XCTAssertEqual(metadata["title"] as? String, "Keep title")

        await repository.saveDocumentOCR(for: file, text: "  ", provider: "vision",
                                         model: "VNRecognizeText", startedAt: Date())
        let afterEmpty = await buildNote(for: file)
        XCTAssertEqual(afterEmpty.text, "New OCR")
    }

    func testScreenshotOCRDoesNotReplaceTheAudioTranscript() async throws {
        let file = tempDir.appendingPathComponent("recording.m4a")
        try Data([1]).write(to: file)
        FileStore.upsertMetadata(for: file, updates: ["transcription": ["transcript": "Spoken text"]])
        let repository = AttachmentRepository(metadataRepository: MetadataRepository())
        await repository.saveDocumentOCR(for: file, text: "Screen text", provider: "vision",
                                         model: "VNRecognizeText", startedAt: Date())
        let note = await buildNote(for: file)
        XCTAssertEqual(note.text, "Spoken text")
    }

    func testDocumentWithTranscriptIsNotFailed() async throws {
        let file = tempDir.appendingPathComponent("scan.pdf")
        try Data(repeating: 1, count: 16).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "transcription": ["transcript": "распознанный текст документа"]
        ])

        let note = await buildNote(for: file)

        XCTAssertFalse(note.isFailed)
        XCTAssertEqual(note.text, "распознанный текст документа")
    }

    func testDocumentWithOnlyDocumentTextFallsBackAndIsNotFailed() async throws {
        // Older imports stored extracted text only under document.text.
        let file = tempDir.appendingPathComponent("photo.jpg")
        try Data(repeating: 1, count: 16).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "document": ["text": "текст с фотографии", "textProvider": "ocr"]
        ])

        let note = await buildNote(for: file)

        XCTAssertFalse(note.isFailed)
        XCTAssertEqual(note.text, "текст с фотографии")
    }

    func testDocumentWithoutAnyTextIsFailed() async throws {
        let file = tempDir.appendingPathComponent("blank.jpg")
        try Data(repeating: 1, count: 16).write(to: file)

        let note = await buildNote(for: file)

        XCTAssertTrue(note.isFailed)
        XCTAssertEqual(note.text, "No text recognized")
    }

    func testSourceMetadataMarksNoteAsImported() async throws {
        let file = tempDir.appendingPathComponent("imported.txt")
        try "Imported text".write(to: file, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: file, updates: ["sourcePath": "/original/imported.txt"])

        let note = await buildNote(for: file)

        XCTAssertTrue(note.isImported)
    }
}
