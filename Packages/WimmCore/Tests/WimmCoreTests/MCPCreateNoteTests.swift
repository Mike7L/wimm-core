import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure

final class MCPCreateNoteTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-capture-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func capture(_ arguments: [String: Any], privateMode: Bool = false,
                         allowedTools: Set<String>? = nil) async -> [String: Any] {
        let destination = directory!
        let server = MCPRecallServer(isPrivate: { privateMode }, allowedTools: allowedTools,
                                     noteDirectory: { destination }, library: { RecallLibrary([]) })
        return await server.callTool(name: "create_note", arguments: arguments)
    }

    func testMarkdownSurvivesLibraryBuildAndRecall() async throws {
        let markdown = "# Решение\n\nОбсудили **Wimm**.\n\n- [ ] Проверить\n"
        let result = await capture(["title": "Итоги обсуждения", "markdown": markdown])
        XCTAssertNil(result["isError"])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "md" })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), markdown)
        XCTAssertTrue(FileStore.isSupportedRecordingFile(file))
        let note = await NoteBuilder.build(file: file, index: 0, metaRepo: MetadataRepository(),
                                           transcriptRepo: TranscriptRepository())
        XCTAssertFalse(note.isFailed)
        XCTAssertEqual(note.title, "Итоги обсуждения")
        XCTAssertEqual(note.text, markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue(try XCTUnwrap(content.first?["text"] as? String).contains(note.id.uuidString),
                      "Returned \(content); expected \(note.id) for \(file.path)")
        let sidecar = try XCTUnwrap(RecallSidecar.load(forRecordingURL: file))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecar.data) as? [String: Any])
        XCTAssertEqual((raw["origin"] as? [String: String])?["source"], "agent-discussion")
        XCTAssertNotNil(raw["recordingId"])
        XCTAssertNil(raw["noteCard"])
        // The file is the body; no second copy that could go stale.
        XCTAssertNil((raw["document"] as? [String: Any])?["text"])
        XCTAssertEqual((raw["document"] as? [String: Any])?["title"] as? String, "Итоги обсуждения")
        let recall = RecallNote(note: note, sidecar: raw)
        let reader = MCPRecallServer(isPrivate: { false }, library: { RecallLibrary([recall]) })
        let read = reader.readNote(recall, full: true).text
        XCTAssertTrue(read.contains("source: agent-discussion"))
        XCTAssertTrue(read.contains(markdown.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testInvalidOrUnauthorizedCallsWriteNothing() async {
        for arguments: [String: Any] in [[:], ["title": "T", "markdown": "  \n"],
                                        ["title": " ", "markdown": "text"],
                                        ["title": "T", "markdown": String(repeating: "x", count: 1_000_001)]] {
            let result = await capture(arguments)
            XCTAssertEqual(result["isError"] as? Bool, true)
        }
        let privateResult = await capture(["title": "T", "markdown": "text"], privateMode: true)
        XCTAssertEqual(privateResult["isError"] as? Bool, true)
        let restricted = await capture(["title": "T", "markdown": "text"], allowedTools: ["get_note"])
        XCTAssertEqual(restricted["isError"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTwoNotesInSameSecondNeverOverwrite() async throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try MarkdownNoteCapture.save(title: "T", markdown: "first", directory: directory, date: date)
        let second = try MarkdownNoteCapture.save(title: "T", markdown: "second", directory: directory, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }
}
