import WimmDomain
import XCTest
@testable import WimmInfrastructure

final class NoteBuilderSearchMetadataTests: XCTestCase {
    func testEmptyTranscriptNoteIsSearchableByFileNameAndRecordingId() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Zahnarzt termin.m4a")
        try Data().write(to: file)
        let metadata: [String: Any] = [
            "recordingId": "DAD75C63-C0BF-41CC-B8D7-705EE119AED8",
            "sourcePath": "/Dropbox/Docs/Family/Zahnarzt termin.m4a",
            "transcription": [
                "provider": "gemini",
                "model": "gemini-flash-lite-latest",
                "transcript": "",
                "audioDurationSec": 2_164.64
            ]
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: FileStore.metadataURL(forRecordingURL: file))

        let note = await NoteBuilder.build(
            file: file,
            index: 0,
            metaRepo: MetadataRepository(),
            transcriptRepo: TranscriptRepository()
        )
        let service = NotesQueryService()

        XCTAssertTrue(note.isFailed)
        XCTAssertEqual(service.textMatchIndices(notes: [note], query: "termin"), [0])
        XCTAssertEqual(service.textMatchIndices(notes: [note], query: "zahnarzt"), [0])
        XCTAssertEqual(
            service.textMatchIndices(
                notes: [note],
                query: "DAD75C63-C0BF-41CC-B8D7-705EE119AED8"
            ),
            [0]
        )
    }

    func testSearchTextKeepsTheSidecarBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("note.m4a")
        try Data().write(to: file)
        let sidecar = """
        {
          "zzLast" : "alpha-marker",
          "aaFirst" : "beta"
        }
        """
        let metadataURL = FileStore.metadataURL(forRecordingURL: file)
        try sidecar.write(to: metadataURL, atomically: true, encoding: .utf8)

        let note = await NoteBuilder.build(
            file: file, index: 0,
            metaRepo: MetadataRepository(), transcriptRepo: TranscriptRepository()
        )

        XCTAssertTrue(note.metadataSearchText.contains("zzlast"))
        XCTAssertLessThan(
            note.metadataSearchText.range(of: "zzlast")!.lowerBound,
            note.metadataSearchText.range(of: "aafirst")!.lowerBound
        )
        XCTAssertEqual(
            NotesQueryService().textMatchIndices(notes: [note], query: "alpha-marker"),
            [0]
        )
    }

    func testUnicodeEscapeInSidecarStaysSearchable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("note.m4a")
        try Data().write(to: file)
        // Raw string keeps the backslash so the file stores JSON \u escapes.
        let sidecar = #"{"sourcePath":"\u041a\u0438\u043d\u0434\u0435\u0440"}"#
        try sidecar.write(
            to: FileStore.metadataURL(forRecordingURL: file),
            atomically: true, encoding: .utf8
        )

        let note = await NoteBuilder.build(
            file: file, index: 0,
            metaRepo: MetadataRepository(), transcriptRepo: TranscriptRepository()
        )
        XCTAssertEqual(
            NotesQueryService().textMatchIndices(notes: [note], query: "киндер"),
            [0]
        )
    }

    func testNoteCardComesFromTheSingleParse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("note.m4a")
        try Data().write(to: file)
        let metadata: [String: Any] = [
            "transcription": ["transcript": "spoken words", "provider": "gemini", "model": "m"],
            "noteCard": [
                "schema": "note-card",
                "note_file": "note.m4a",
                "title": "Card Title",
                "summary": "Card summary",
                "is_liked": true
            ]
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: FileStore.metadataURL(forRecordingURL: file))

        let note = await NoteBuilder.build(
            file: file, index: 0,
            metaRepo: MetadataRepository(), transcriptRepo: TranscriptRepository()
        )
        XCTAssertEqual(note.title, "Card Title")
        XCTAssertEqual(note.summary, "Card summary")
        XCTAssertTrue(note.isLiked)
        XCTAssertEqual(note.text, "spoken words")
    }
}
