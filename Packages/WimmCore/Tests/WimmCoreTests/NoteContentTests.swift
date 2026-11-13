import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// One rule set for a note's body and kind (`NoteContent`), and the readers on it.
final class NoteContentTests: XCTestCase {
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

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // MARK: - Pure rules

    func testKindByExtension() {
        XCTAssertEqual(NoteContent.kind(of: url("a.m4a")), .audio)
        XCTAssertEqual(NoteContent.kind(of: url("a.PDF")), .pdf)
        XCTAssertEqual(NoteContent.kind(of: url("a.heic")), .image)
        XCTAssertEqual(NoteContent.kind(of: url("a.heif")), .image)
        for ext in ["txt", "md", "markdown"] {
            XCTAssertEqual(NoteContent.kind(of: url("a.\(ext)")), .text, ext)
        }
        XCTAssertEqual(NoteContent.kind(of: url("a.docx")), .document)
        XCTAssertEqual(RecallNote.kind(of: url("a.md")), "text")
        XCTAssertEqual(AttachmentSplitMigration.kind(of: url("a.docx")), "other")
    }

    func testTextNoteBodyIsTheFileNotTheSidecarCopy() {
        let content = NoteContent.resolve(
            anchor: url("n.md"),
            sidecar: ["document": ["text": "stale copy"], "transcription": ["transcript": "not it"]],
            typedFileText: "  edited file\n")
        XCTAssertEqual(content.kind, .text)
        XCTAssertTrue(content.isTypedFile)
        XCTAssertEqual(content.body, "edited file")
        XCTAssertEqual(content.bodySource, .typedFile)
    }

    func testEmptyTextFileHasNoBodyAndIgnoresTheSidecarCopy() {
        let content = NoteContent.resolve(anchor: url("n.txt"), sidecar: ["document": ["text": "x"]], typedFileText: "  ")
        XCTAssertNil(content.body)
        XCTAssertNil(content.bodySource)
        XCTAssertFalse(content.fileUnreadable)
        XCTAssertEqual(content.fileText, "  ")
    }

    // MARK: - Unreadable is not empty (stage 5)

    func testUnreadableTextFileFallsBackToSidecarCopyAndSaysSo() {
        let content = NoteContent.resolve(anchor: url("n.txt"), sidecar: ["document": ["text": " copy "]], typedFileText: nil)
        XCTAssertTrue(content.fileUnreadable)
        XCTAssertEqual(content.body, "copy")
        XCTAssertEqual(content.bodySource, .documentText)
        XCTAssertNil(content.fileText)

        let bare = NoteContent.resolve(anchor: url("n.md"), sidecar: ["transcription": ["transcript": "not it"]], typedFileText: nil)
        XCTAssertTrue(bare.fileUnreadable)
        XCTAssertNil(bare.body)
    }

    func testLoadTellsUnreadableFromEmpty() throws {
        let empty = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let emptyContent = NoteContent.load(anchor: empty, sidecar: ["document": ["text": "copy"]])
        XCTAssertFalse(emptyContent.fileUnreadable)
        XCTAssertNil(emptyContent.body)

        // Not UTF-8 (a lone 0xFF byte in Latin-1 text).
        let latin = tempDir.appendingPathComponent("latin.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0xFF]).write(to: latin)
        let latinContent = NoteContent.load(anchor: latin, sidecar: ["document": ["text": "café"]])
        XCTAssertTrue(latinContent.fileUnreadable)
        XCTAssertEqual(latinContent.body, "café")

        // Not downloaded: the listed file is not on disk.
        let missing = NoteContent.load(anchor: tempDir.appendingPathComponent("evicted.md"), sidecar: [:])
        XCTAssertTrue(missing.fileUnreadable)
        XCTAssertNil(missing.body)

        // Other kinds never read a file and are never "unreadable".
        XCTAssertFalse(NoteContent.load(anchor: tempDir.appendingPathComponent("r.m4a"), sidecar: [:]).fileUnreadable)
    }

    func testReadersSayTheFileCouldNotBeRead() async throws {
        let withCopy = tempDir.appendingPathComponent("import.txt")
        try Data([0xFF, 0xFE, 0x00]).write(to: withCopy)
        FileStore.upsertMetadata(for: withCopy, updates: ["document": ["text": "sidecar copy"]])
        let note = await build(withCopy)
        XCTAssertEqual(note.text, "sidecar copy")
        let record = await TranscriptRepository().textOfRecord(for: withCopy)
        XCTAssertEqual(record, "sidecar copy")
        let readText = await read(withCopy)
        XCTAssertTrue(readText.contains("file_unreadable:"), readText)

        let bare = tempDir.appendingPathComponent("bare.txt")
        try Data([0xFF, 0xFE, 0x00]).write(to: bare)
        let bareNote = await build(bare)
        XCTAssertEqual(bareNote.text, NoteContent.unreadableFilePlaceholder)
        XCTAssertFalse(bareNote.isFailed)
        let bareRecord = await TranscriptRepository().textOfRecord(for: bare)
        XCTAssertNil(bareRecord)
    }

    func testAudioUsesTranscriptThenLegacyStringButNeverDocumentText() {
        let anchor = url("r.m4a")
        XCTAssertEqual(NoteContent.resolve(anchor: anchor, sidecar: ["transcription": ["transcript": " said "]],
                                           typedFileText: nil).body, "said")
        let legacy = NoteContent.resolve(anchor: anchor, sidecar: ["transcription": "iphone text"], typedFileText: nil)
        XCTAssertEqual(legacy.body, "iphone text")
        XCTAssertEqual(legacy.bodySource, .legacyTranscript)
        XCTAssertNil(NoteContent.resolve(anchor: anchor, sidecar: ["document": ["text": "doc"]], typedFileText: nil).body)
    }

    func testDocumentFallsBackToDocumentText() {
        let content = NoteContent.resolve(anchor: url("scan.pdf"), sidecar: ["document": ["text": "page"]], typedFileText: nil)
        XCTAssertEqual(content.body, "page")
        XCTAssertEqual(content.bodySource, .documentText)
    }

    // MARK: - Readers

    private func build(_ file: URL) async -> Note {
        await NoteBuilder.build(file: file, index: 0, metaRepo: MetadataRepository(),
                                transcriptRepo: TranscriptRepository())
    }

    /// The evening journal case: a `.md` with a sidecar but no `document.text`
    /// showed "No text recognized" in the app while MCP read the file.
    func testMarkdownWithoutDocumentTextShowsItsFile() async throws {
        let file = tempDir.appendingPathComponent("Wimm_2026-11-01_19-57-05_9C23FC5A.md")
        try "# Вечер\n\nТекст журнала".write(to: file, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: file, updates: ["title": "Вечерний журнал"])
        let note = await build(file)
        XCTAssertEqual(note.text, "# Вечер\n\nТекст журнала")
        XCTAssertFalse(note.isFailed)
        let repo = TranscriptRepository()
        let recordText = await repo.textOfRecord(for: file)
        XCTAssertEqual(recordText, "# Вечер\n\nТекст журнала")
    }

    /// A `create_note` note keeps a copy in `document.text`; after the file is
    /// edited the app must show the file, not the stale copy.
    func testEditedMarkdownWinsOverStaleSidecarCopy() async throws {
        let file = tempDir.appendingPathComponent("agent.md")
        try "new body".write(to: file, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: file, updates: ["document": ["title": "T", "text": "old body"]])
        let note = await build(file)
        XCTAssertEqual(note.text, "new body")
        let transcript = await TranscriptRepository().transcriptText(for: file)
        XCTAssertEqual(transcript, "new body")
    }

    func testPlainTextNoteUnchanged() async throws {
        let file = tempDir.appendingPathComponent("typed.txt")
        try " typed \n".write(to: file, atomically: true, encoding: .utf8)
        let note = await build(file)
        XCTAssertEqual(note.text, "typed")
        XCTAssertFalse(note.isFailed)
    }

    private func read(_ file: URL) async -> String {
        let note = await build(file)
        let sidecar = await MetadataRepository().metadata(for: file)
        let recall = RecallNote(note: note, sidecar: sidecar)
        let reader = MCPRecallServer(isPrivate: { false }, library: { RecallLibrary([recall]) })
        return reader.readNote(recall, full: true).text
    }

    /// readNote: an equal sidecar copy (also with other line endings) is not shown
    /// twice; a different one is flagged as an old copy, never as the note's text.
    func testReadNoteHidesEqualCopyAndFlagsStaleOne() async throws {
        let same = tempDir.appendingPathComponent("same.txt")
        try "line one\nline two".write(to: same, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: same, updates: ["document": ["text": "line one\r\nline two", "textProvider": "plain-text"]])
        let sameRead = await read(same)
        XCTAssertFalse(sameRead.contains("stale sidecar copy"), sameRead)
        XCTAssertFalse(sameRead.contains("document (extracted)"), sameRead)
        XCTAssertTrue(sameRead.contains("line two"))

        let edited = tempDir.appendingPathComponent("edited.md")
        try "new body".write(to: edited, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: edited, updates: ["document": ["title": "T", "text": "old body"]])
        let editedRead = await read(edited)
        XCTAssertTrue(editedRead.contains("document (stale sidecar copy, not the note's text)"), editedRead)
        XCTAssertTrue(editedRead.contains("new body"))
    }

    /// A lost recording turned into `.txt` (header + transcript) beside its old
    /// sidecar: readNote shows the text once, as the file.
    func testReadNoteShowsLostToTextBodyOnce() async throws {
        let file = tempDir.appendingPathComponent("Wimm_2026-01-14_09-12-03_ABCD1234.txt")
        try "[Расшифровка утраченной аудиозаписи · 1 мин · записано 2026-01-14 09:12]\n\nсказанное раз\r\nи два".write(to: file, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: file, updates: ["transcription": ["transcript": "сказанное раз\nи два ", "provider": "gemini"]])
        let text = await read(file)
        XCTAssertEqual(text.components(separatedBy: "сказанное раз").count - 1, 1, text)
        XCTAssertTrue(text.contains("--- primary document ---"), text)

        // A sidecar transcript that the file does not carry is still shown, after the primary document.
        let other = tempDir.appendingPathComponent("typed.txt")
        try "typed body".write(to: other, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: other, updates: ["transcription": ["transcript": "something else"]])
        let otherText = await read(other)
        XCTAssertTrue(otherText.contains("something else"), otherText)
        let docIndex = try XCTUnwrap(otherText.range(of: "--- primary document ---\ntyped body")?.lowerBound)
        let sidecarIndex = try XCTUnwrap(otherText.range(of: "something else")?.lowerBound)
        XCTAssertLessThan(docIndex, sidecarIndex)
    }
}
