import XCTest
import WimmDomain
import WimmInfrastructure

final class LLMBundleExporterTests: XCTestCase {
    func testGenerateMarkdownChronicleForNotesUsesInMemoryNoteContent() async throws {
        let exporter = LLMBundleExporter()
        let misleadingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-misleading-\(UUID().uuidString).txt")
        try "wrong disk content from another note".write(to: misleadingFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: misleadingFile) }

        let note = makeNote(
            fileURL: misleadingFile,
            text: "selected in-memory note text",
            refinedText: "selected refined in-memory note text"
        )

        let markdown = await exporter.generateMarkdownChronicle(for: [note])

        XCTAssertTrue(markdown.contains("selected refined in-memory note text"))
        XCTAssertFalse(markdown.contains("wrong disk content from another note"))
    }

    func testGenerateMarkdownChronicleForNotesDoesNotDropUnprocessedShortNotes() async {
        let exporter = LLMBundleExporter()
        let note = makeNote(text: "short", processedAt: nil)

        let markdown = await exporter.generateMarkdownChronicle(for: [note])

        XCTAssertTrue(markdown.contains("short"))
        XCTAssertTrue(markdown.contains("Entries: 1"))
    }

    func testGenerateMarkdownChronicleForNotesSkipsCanceledNotes() async {
        let exporter = LLMBundleExporter()
        let kept = makeNote(text: "kept selected note text")
        let canceled = makeNote(text: "canceled selected note text", isCanceled: true)

        let markdown = await exporter.generateMarkdownChronicle(for: [kept, canceled])

        XCTAssertTrue(markdown.contains("kept selected note text"))
        XCTAssertFalse(markdown.contains("canceled selected note text"))
        XCTAssertTrue(markdown.contains("Entries: 1"))
    }

    private func makeNote(
        fileURL: URL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).txt"),
        text: String,
        refinedText: String? = nil,
        processedAt: Date? = Date(timeIntervalSince1970: 1),
        isCanceled: Bool = false
    ) -> Note {
        Note(
            id: UUID(),
            index: 0,
            fileURL: fileURL,
            fileCreated: Date(timeIntervalSince1970: 1),
            start: 0,
            end: 1,
            text: text,
            refinedText: refinedText,
            isFailed: false,
            hasRaw: false,
            title: "Selected Note",
            processedAt: processedAt,
            isCanceled: isCanceled
        )
    }
}
