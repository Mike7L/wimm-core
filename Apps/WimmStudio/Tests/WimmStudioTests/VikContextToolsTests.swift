import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class VikContextToolsTests: XCTestCase {
    private let document = "# Документ\n\n## Семья\n\nЖивут в Киле.\n\n## Работа\n\nДругая тема."
    private var current: URL { StoragePaths.baseDirectory().appendingPathComponent("Wimm_2026-11-06_19-00-00_CURRENT.aac") }

    func testReadsSecretaryOutlineSectionAndExactBlocksWithoutChangingDocument() async throws {
        let tools = VikContextTools(document: document, source: current, isAllowed: { true }, files: { [] })
        let outline = try object(await tools.read("document_outline", arguments: "{}"))
        let items = try XCTUnwrap(outline["items"] as? [[String: Any]])
        let family = try XCTUnwrap(items.first { ($0["title"] as? String) == "## Семья" }?["id"] as? String)
        let section = try object(await tools.read("document_section", arguments: "{\"id\":\"\(family)\"}"))
        XCTAssertEqual(section["status"] as? String, "complete")
        let blocks = try XCTUnwrap(section["blocks"] as? [[String: Any]])
        let body = try XCTUnwrap(blocks.first { ($0["text"] as? String)?.contains("Киле") == true }?["id"] as? String)
        let read = try await tools.read("document_blocks", arguments: "{\"ids\":[\"\(body)\",\"b999999\"]}")
        XCTAssertTrue(read.contains("Киле")); XCTAssertFalse(read.contains("Другая тема"))
        XCTAssertEqual(try object(read)["missing"] as? [String], ["b999999"])
        let transcript = await tools.transcript()
        XCTAssertTrue(transcript.contains("document_section")); XCTAssertTrue(transcript.contains("Киле"))
    }

    func testPreviousAndHourExcludeCurrentAndFutureAndReadLegacyLiveEvidence() async throws {
        let dir = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["Wimm_2026-11-06_17-00-00_OLD.txt", "Wimm_2026-11-06_18-30-00_PRIOR.aac",
                     "Wimm_2026-11-06_19-00-00_CURRENT.aac", "Wimm_2026-11-06_19-01-00_FUTURE.txt"]
        let files = names.map { dir.appendingPathComponent($0) }
        try Data("Старое".utf8).write(to: files[0])
        try Data().write(to: files[1])
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: files[1])) { meta in
            meta["transcription"] = ["localTranscript": "Они живут в Киле", "transcript": "Они живут у моря", "provider": "parakeet"]
            return true
        }
        let now = try XCTUnwrap(FileStore.recordingDateFromFileName(files[2])).addingTimeInterval(12)
        let tools = VikContextTools(document: "", source: files[2], asOf: now, isAllowed: { true }, files: { files })
        let list = try object(await tools.read("notes_last_hour", arguments: "{}"))
        XCTAssertEqual(list["total"] as? Int, 1)
        let previous = try await tools.read("previous_note", arguments: "{}")
        XCTAssertTrue(previous.contains("Киле")); XCTAssertTrue(previous.contains("у моря"))
        XCTAssertFalse(previous.contains("Старое"))
        let id = try XCTUnwrap(try object(previous)["id"] as? String)
        let exact = try await tools.read("read_note", arguments: "{\"id\":\"\(id)\"}")
        XCTAssertEqual(try object(exact)["text"] as? String, try object(previous)["text"] as? String)
        let missing = try await tools.read("read_note", arguments: "{\"id\":\"../secret\"}")
        XCTAssertTrue(missing.hasPrefix("not_found"))
    }

    func testRevokedReadReturnsNoEvidenceEvenWhenLoaderFinishesLate() async throws {
        let gate = ReadGate()
        let source = current
        let tools = VikContextTools(document: document, source: source, isAllowed: { await gate.allowed },
                                    files: { [source.deletingLastPathComponent().appendingPathComponent("Wimm_2026-11-06_18-59-00_PREV.txt")] },
                                    load: { _ in await gate.load() })
        let task = Task { try await tools.read("previous_note", arguments: "{}") }
        for _ in 0..<200 { if await gate.loading { break }; try await Task.sleep(for: .milliseconds(2)) }
        await gate.revoke()
        do { _ = try await task.value; XCTFail("revoked read must fail") } catch is CancellationError {} 
        let transcript = await tools.transcript()
        XCTAssertTrue(transcript.isEmpty)
    }

    func testDeniedAccessNeverTouchesFiles() async {
        let tools = VikContextTools(document: document, source: current, isAllowed: { false }, files: { XCTFail("must not read"); return [] })
        do { _ = try await tools.read("notes_last_hour", arguments: "{}"); XCTFail("must refuse") } catch {}
        do { _ = try await tools.read("document_outline", arguments: "{}"); XCTFail("must refuse") } catch {}
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private actor ReadGate {
    var allowed = true
    var loading = false
    private var continuation: CheckedContinuation<RecallLibrary, Never>?
    func load() async -> RecallLibrary {
        loading = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func revoke() { allowed = false; continuation?.resume(returning: RecallLibrary([])); continuation = nil }
}
