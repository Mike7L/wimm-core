import Foundation
import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryPacketFilesTests: XCTestCase {
    private var root: URL!
    private var marks: AgentMarkStore!
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registry: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }
    private var files: [URL] { ["one", "two"].map { root.appendingPathComponent("recordings/\($0).txt") } }
    private var library: RecallLibrary {
        RecallLibrary(files.enumerated().map { index, file in
            RecallNote(id: "note-\(index)", date: Date(), kind: "text", title: "Маяк", summary: nil,
                       text: "cached text must not be used", filePath: file.path, updated: Date())
        })
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secretary-files-\(UUID().uuidString)")
        for path in ["docs", "recordings", "secretary/protocol"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        marks = AgentMarkStore(directory: root.appendingPathComponent("state"))
        for (i, file) in files.enumerated() {
            try "Источник \(i): «Ёж 🦔»; это план, не исполненное действие.\n".write(to: file, atomically: true, encoding: .utf8)
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { $0["recordingId"] = "note-\(i)"; return true }
        }
        try "# Личный документ\n\n## Маяк\n\nСтарый факт [S1].\n\n## Другая тема\n\nСтарый факт [S2].\n\n[S1]: ../recordings/one.meta.json\n[S2]: ../recordings/two.meta.json\n".write(to: document, atomically: true, encoding: .utf8)
        try "Сохранять все варианты и различать планы и факты.".write(to: root.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\nНет.\n".write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        let rows = files.enumerated().map { i, file in
            ["source_id": "S\(i + 1)", "path": "../recordings/\(file.deletingPathExtension().lastPathComponent).meta.json",
             "note_file": file.lastPathComponent, "status": "pending", "reason": "unread"]
        }
        try JSONSerialization.data(withJSONObject: ["sources": rows, "source_count": 2, "counts": ["pending": 2], "batches": []]).write(to: registry)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func prepare() async throws -> [String: Any] {
        try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 64, library: library, marks: marks))
    }

    func testUnreadPendingSelectionExcludesReadSettledHeldAndRemovedSources() {
        func row(_ id: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            ["source_id": id, "note_file": "\(id).txt", "status": "pending", "primary_text_read": false]
                .merging(fields) { _, new in new }
        }
        let rows = [row("S1"), row("S2", ["primary_text_read": true]), row("S3", ["status": "applied"]),
                    row("S4", ["user_exclusion": ["active": true, "authority": "user"]]),
                    row("S5", ["removed_from_wimm": true]), row("S6", ["wimm_unindexed": true]),
                    row("S7", ["status": "noise"])]
        XCTAssertEqual(SecretaryPacketFiles.unreadPendingSourceIDs(rows), ["S1"])
        XCTAssertTrue(SecretaryPacketFiles.unreadPendingSourceIDs(rows, excluding: ["S1"]).isEmpty)
        XCTAssertEqual(SecretaryPacketFiles.unreadPendingSourceIDs(rows), ["S1"], "sweep exclusions never settle or mutate a source")
    }

    func testUnreadPendingAdmitsOldUnchangedMarkedNoteWithoutReopeningReadNote() async throws {
        var data = try object(Data(contentsOf: registry))
        var rows = data["sources"] as! [[String: Any]]
        rows[0]["primary_text_read"] = false
        rows[1]["primary_text_read"] = true
        data["sources"] = rows
        try JSONSerialization.data(withJSONObject: data).write(to: registry)
        let fp = NoteFingerprint.read(forRecordingURL: files[0])
        try marks.update([files[0].lastPathComponent: .init(status: .pending, source: "S1", markedAt: Date(),
            noteId: "note-0", text: fp.text, analysis: fp.analysis)])
        try marks.setPass(.init(asOf: .distantFuture, cursor: nil, comment: nil, setAt: Date()))
        let m = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 64, library: library, marks: marks, unreadPending: true))
        XCTAssertEqual(m["source_count"] as? Int, 1)
        let input = try object(Data(contentsOf: URL(fileURLWithPath: m["input"] as! String)))
        XCTAssertEqual((input["sources"] as? [[String: Any]])?.compactMap { $0["source"] as? String }, ["S1"])
        XCTAssertEqual(marks.mark(forFile: files[0].lastPathComponent)?.status, .pending)
    }

    func testUnreadPendingLeavesOverflowForLaterPackets() async throws {
        for file in files {
            try String(repeating: "A", count: 45_000).write(to: file, atomically: true, encoding: .utf8)
        }
        let m = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 64, library: library, marks: marks, unreadPending: true))
        XCTAssertEqual(m["source_count"] as? Int, 1)
        XCTAssertTrue(marks.marks().isEmpty)
        let rows = try object(Data(contentsOf: registry))["sources"] as! [[String: Any]]
        XCTAssertEqual(rows.filter { $0["status"] as? String == "pending" }.count, 2)
    }

    func testTwoHundredKBIsNotRoundedTo192() async throws {
        for file in files {
            try String(repeating: "A", count: 99_000).write(to: file, atomically: true, encoding: .utf8)
        }
        let m = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 200, library: library, marks: marks, unreadPending: true))
        XCTAssertEqual(m["source_budget_bytes"] as? Int, 200_000)
        XCTAssertEqual(m["source_count"] as? Int, 2)
        XCTAssertGreaterThan(m["source_text_bytes"] as! Int, 192_000)
        XCTAssertLessThanOrEqual(m["source_text_bytes"] as! Int, 200_000)
    }

    func testExpandedContextBudgetReadsLongSectionWithoutChangingSourcesOrMarks() async throws {
        let paragraphs = (0..<14).map { "Paragraph \($0): " + String(repeating: "long document context ", count: 600) }.joined(separator: "\n\n")
        try ("# Document\n\n## Long section\n\n" + paragraphs + "\n").write(to: document, atomically: true, encoding: .utf8)
        let original = try Data(contentsOf: document)
        let m = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 64, library: library, marks: marks, contextKB: 256))
        XCTAssertEqual(m["document_read_budget_bytes"] as? Int, 256_000)
        let id = m["run_id"] as! String
        var offset = 0, complete = false
        for _ in 0..<20 {
            let result = try read(id, "section", "Long section", offset: offset, limit: 24_000)
            let item = (result["read_results"] as! [[String: Any]])[0]
            if item["status"] as? String == "complete" { complete = true; break }
            let next = item["next_offset"] as? Int ?? offset
            XCTAssertGreaterThan(next, offset)
            if next <= offset { break }
            offset = next
        }
        XCTAssertTrue(complete)
        XCTAssertTrue(marks.marks().isEmpty)
        XCTAssertEqual(try Data(contentsOf: document), original)
    }

    func testExplicitPendingAttachmentUsesNativeReaderWithoutAdmittingPDFPreview() async throws {
        let attachment = root.appendingPathComponent("recordings/one_Attach_Text.txt")
        try "Полный текст вложения, который журнал группирует с родителем.".write(to: attachment, atomically: true, encoding: .utf8)
        let sidecar = FileStore.metadataURL(forRecordingURL: attachment)
        try FileStore.mutateSidecar(at: sidecar) { $0["recordingId"] = "attachment-fixture"; return true }
        let pdf = root.appendingPathComponent("recordings/preview.pdf"), preview = root.appendingPathComponent("recordings/preview.heic")
        try Data("fixture".utf8).write(to: pdf); try Data("fixture".utf8).write(to: preview)
        let rows: [[String: Any]] = [
            ["source_id": "S3", "note_file": attachment.lastPathComponent, "path": "../recordings/" + sidecar.lastPathComponent],
            ["source_id": "S4", "note_file": preview.lastPathComponent, "path": "../recordings/preview.meta.json"]]
        let built = try await SecretaryPacketFiles.supplementSelectedFiles(library, rows: rows, ids: ["S3", "S4"], root: root, documentDirectory: document.deletingLastPathComponent())
        XCTAssertEqual(built.count, library.count + 1)
        XCTAssertTrue((0..<built.count).contains { built[$0].filePath == attachment.path })
        XCTAssertFalse((0..<built.count).contains { built[$0].filePath == preview.path })
        let packetRows = try object(Data(contentsOf: registry))["sources"] as! [[String: Any]]
        try JSONSerialization.data(withJSONObject: ["sources": packetRows + [rows[0].merging(["status": "pending"]) { _, b in b }], "source_count": 3, "counts": ["pending": 3], "batches": []]).write(to: registry)
        let result = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 64, library: library, marks: marks, unreadPending: true))
        XCTAssertTrue((result["source_ids"] as! [String]).contains("S3"))
        XCTAssertTrue(marks.marks().isEmpty)
        let body = try JSONSerialization.data(withJSONObject: ["done_no_additions": ["S1", "S2", "S3"].map { ["source": $0, "reason": "Повтор."] }])
        let applied = try object(await SecretaryPacketFiles.apply(runID: result["run_id"] as! String, response: body,
            marks: marks, recordings: { self.files }))
        XCTAssertEqual(Set(applied["stored_sources"] as! [String]), ["S1", "S2", "S3"])
        XCTAssertEqual(marks.marks()[attachment.lastPathComponent]?.source, "S3")
        XCTAssertEqual(marks.marks()[files[0].lastPathComponent]?.source, "S1")
        XCTAssertTrue((applied["findings"] as! [String]).isEmpty)
    }

    func testRetryFeedbackIsBoundToItsSourcesAndNeverAppliesRejectedEdits() async throws {
        let manifest = try await prepare(), id = manifest["run_id"] as! String
        let before = try Data(contentsOf: document)
        let body = try JSONSerialization.data(withJSONObject: ["edits": [["operation": "insert_after", "block": "b0", "match": "invalid extra field", "text": "Новый факт [S1].", "sources": ["S1"]]]])
        let result = try object(await SecretaryPacketFiles.apply(runID: id, response: body, marks: marks, recordings: { self.files }))
        XCTAssertEqual(result["accepted"] as? Bool, false)
        let directory = root.appendingPathComponent("secretary/runs/" + id)
        let feedback = SecretaryPacketFiles.priorValidationFeedback(directory: directory, sourceIDs: ["S1", "S2"])
        XCTAssertTrue(feedback?.contains("HOST VALIDATION FEEDBACK") == true)
        XCTAssertNil(SecretaryPacketFiles.priorValidationFeedback(directory: directory, sourceIDs: ["S9"]))
        XCTAssertTrue(marks.marks().isEmpty)
        XCTAssertEqual(try Data(contentsOf: document), before)
    }

    func testHistoricalReplayUsesSnapshotWithoutChangingCurrentWorkspaceOrSession() async throws {
        try "Сохраняй факты.".write(to: root.appendingPathComponent("secretary/protocol/packet-edits.md"), atomically: true, encoding: .utf8)
        let m = try await prepare(), id = m["run_id"] as! String
        let session = marks.directory.appendingPathComponent("SecretaryFileSessions/\(id).json")
        let sessionBefore = try Data(contentsOf: session)
        let state = try SecretaryPacketFiles.load(id, marks: marks)
        let policy = SecretaryPacket.editsResponseContract + "\n\nWorkspace semantic policy:\n" + String(decoding: state.workspacePolicy, as: UTF8.self)
        let prompt = SecretaryPacketFiles.masked(try SecretaryPacketFiles.packetPages(state, inlinePolicy: policy).joined(separator: "\n\n"))
        let request = root.appendingPathComponent("original-request.json")
        try JSONSerialization.data(withJSONObject: ["contents": [["parts": [["text": prompt]]]],
            "systemInstruction": ["parts": [["text": "Return JSON"]]]]).write(to: request)
        try "# Current document has moved on\n".write(to: document, atomically: true, encoding: .utf8)
        let current = try Data(contentsOf: document), currentRegistry = try Data(contentsOf: registry)
        let output = root.appendingPathComponent("historical-replay")
        let report = try object(await SecretaryPacketFiles.replayGemini(runID: id, originalRequest: request,
            output: output, model: "fixture", marks: marks))
        XCTAssertEqual(report["sent"] as? Bool, false)
        XCTAssertEqual(report["committed"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("workspace/docs/me.md")), state.documentData)
        XCTAssertEqual(try Data(contentsOf: document), current)
        XCTAssertEqual(try Data(contentsOf: registry), currentRegistry)
        XCTAssertEqual(try Data(contentsOf: session), sessionBefore)
        XCTAssertTrue(marks.marks().isEmpty)
        do {
            _ = try await SecretaryPacketFiles.replayGemini(runID: id, originalRequest: request,
                output: output, model: "fixture", marks: marks)
            XCTFail("Existing replay output must not be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("new directory")) }
    }

    func testCapturedBenchmarkUsesNativeValidatorWithoutMutatingWorkspace() async throws {
        try "Сохраняй факты.".write(to: root.appendingPathComponent("secretary/protocol/packet-edits.md"), atomically: true, encoding: .utf8)
        let m = try await prepare()
        let input = URL(fileURLWithPath: m["input"] as! String)
        let d = try object(Data(contentsOf: input))
        let target = (d["document_blocks"] as! [[String: Any]]).first { ($0["text"] as? String)?.contains("Старый факт [S1]") == true }!["id"] as! String
        let response = root.appendingPathComponent("benchmark-response.json")
        try JSONSerialization.data(withJSONObject: ["edits": [["operation": "insert_after", "block": target,
            "text": "Дополнение [S1].", "sources": ["S1"]]], "done_no_additions": [["source": "S2", "reason": "Повтор"]]]).write(to: response)
        let prompt = root.appendingPathComponent("captured.prompt")
        try "Captured benchmark prompt".write(to: prompt, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: document), reg = try Data(contentsOf: registry)
        let output = root.appendingPathComponent("offline-benchmark")
        let result = try object(await SecretaryGeminiBenchmark.run(promptFile: prompt, inputFile: input, documentSnapshot: document,
            registry: registry, output: output, model: "fixture", responseFile: response))
        let validation = result["validation"] as! [String: Any]
        XCTAssertEqual(validation["accepted"] as? Bool, true)
        XCTAssertEqual((validation["edits"] as? [Any])?.count, 1)
        XCTAssertEqual(result["committed"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: document), before)
        XCTAssertEqual(try Data(contentsOf: registry), reg)
        XCTAssertTrue(marks.marks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("unused-marks/marks.json").path))
        try JSONSerialization.data(withJSONObject: ["done_no_additions": ["S1", "S2"]]).write(to: response)
        let invalid = try object(await SecretaryGeminiBenchmark.run(promptFile: prompt, inputFile: input, documentSnapshot: document,
            registry: registry, output: root.appendingPathComponent("offline-invalid"), model: "fixture", responseFile: response))
        let rejected = invalid["validation"] as! [String: Any]
        XCTAssertEqual(rejected["accepted"] as? Bool, false)
        XCTAssertEqual(rejected["native_decoder_rejection"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: document), before)
        XCTAssertEqual(try Data(contentsOf: registry), reg)
    }
    private func read(_ id: String, _ operation: String, _ query: String = "", offset: Int = 0, limit: Int = 8000, refresh: Bool = false) throws -> [String: Any] {
        try object(SecretaryPacketFiles.read(runID: id, operation: operation, query: query, offset: offset,
            limit: limit, refresh: refresh, library: library, marks: marks))
    }
    private func response(_ manifest: [String: Any]) throws -> Data {
        let input = try object(Data(contentsOf: URL(fileURLWithPath: manifest["input"] as! String)))
        let blocks = input["document_blocks"] as! [[String: String]]
        let first = try XCTUnwrap(blocks.first { $0["text"] == "Старый факт [S1].\n\n" })
        let second = try XCTUnwrap(blocks.first { $0["text"] == "Старый факт [S2].\n\n" })
        return try JSONSerialization.data(withJSONObject: [
            "summary": "UNTRUSTED GLOBAL CLAIM: everything finished",
            "edits": [
                ["operation": "replace_text", "block": first["id"]!, "match": "Старый факт", "text": "Новый план [S1].", "sources": ["S1"]],
                ["operation": "replace_text", "block": second["id"]!, "match": "Старый факт", "text": "Новый план [S2].", "sources": ["S2"]]
            ],
            "done_no_additions": [],
            "unfinished": [],
            "not_a_note": [],
            "questions": []
        ])
    }

    func testPrepareRoundTripsAcrossCallsWithoutModelMarksOrDocumentWrites() async throws {
        let before = try Data(contentsOf: document), originalRegistry = try Data(contentsOf: registry)
        let m = try await prepare(), id = m["run_id"] as! String
        XCTAssertEqual(m["source_budget_bytes"] as? Int, 64000)
        XCTAssertEqual(m["source_count"] as? Int, 2)
        XCTAssertLessThanOrEqual(m["source_text_bytes"] as! Int, 64000)
        XCTAssertEqual(try Data(contentsOf: document), before)
        XCTAssertEqual(try Data(contentsOf: registry), originalRegistry)
        XCTAssertTrue(marks.marks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("secretary/runs/.lock").path))
        let outline = try read(id, "outline")
        XCTAssertNotNil(outline["read_results"])
        let policy = try read(id, "part", "policy", limit: 8000)
        XCTAssertTrue((policy["text"] as? String)?.contains("No provider session") == true)
        XCTAssertThrowsError(try read("../escape", "outline"))
        XCTAssertThrowsError(try read(id, "part", "../../recordings/one.txt"))
    }

    func testPacketPagesCarryPolicyBlocksAndEverySourceWhole() async throws {
        let m = try await prepare()
        let order = try XCTUnwrap(m["read_order"] as? [String])
        XCTAssertEqual(order.first.map { URL(fileURLWithPath: $0).lastPathComponent }, "packet-001.md")
        let pages = try order.map { try String(contentsOfFile: $0, encoding: .utf8) }
        let all = pages.joined()
        XCTAssertTrue(pages[0].contains("Прочитай файл целиком."))
        XCTAssertTrue(all.contains("Сохранять все варианты и различать планы и факты."))
        XCTAssertTrue(all.contains("Старый факт [S1].\n\n"))
        XCTAssertTrue(all.contains("## Открытые вопросы"))
        let sources = URL(fileURLWithPath: m["sources"] as! String)
        for id in ["S1", "S2"] {
            let text = try String(contentsOf: sources.appendingPathComponent("\(id).txt"), encoding: .utf8)
            XCTAssertTrue(all.contains("===== источник \(id) =====\n"))
            XCTAssertTrue(all.contains(SecretaryPacketFiles.compactSourceHeader(text)), id)
            XCTAssertTrue(all.contains("===== конец источника \(id) ====="), id)
        }
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testPagesMaskKeysInExportedFiles() async throws {
        for file in files { try "Ключ GEMINI_API_KEY=AIzaSyA1b2C3d4E5f6G7h8I9j0KLmnop и тот же текст.\n".write(to: file, atomically: true, encoding: .utf8) }
        let first = try await prepare()
        let firstPages = try XCTUnwrap(first["read_order"] as? [String]).map { try String(contentsOfFile: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(firstPages.contains("Сохранять все варианты и различать планы и факты."))
        for path in [first["input"], first["sources"].map { "\($0)/S1.txt" }] {
            let text = try String(contentsOfFile: path as! String, encoding: .utf8)
            XCTAssertFalse(text.contains("AIzaSyA1b2"), "key leaked into \(path!)")
            XCTAssertTrue(text.contains("GEMINI_API_KEY=[скрыто]"))
        }
        XCTAssertFalse(firstPages.contains("AIzaSyA1b2"))
        XCTAssertEqual(SecretaryPacketFiles.masked("token sk-ant-api03abcdefghijklmnopqrstuv end"), "token sk-ant-ap…[скрыто] end")
        XCTAssertEqual(SecretaryPacketFiles.masked("обычный текст: token = короткий"), "обычный текст: token = короткий")
        XCTAssertEqual(SecretaryPacketFiles.masked("private var toggleToken: NSObjectProtocol?"), "private var toggleToken: NSObjectProtocol?")
    }

    func testHeaderLinesAndAttentionWarnings() {
        let header = SecretaryPacketFiles.headerLines("""
        speech: speech
        retranscription: done 2026-11-03 (parakeet:ultra): no_speech
        coverage: ~6 s text for 139 s audio — the transcript likely misses most of the recording
        --- transcript (parakeet/ultra, 3 words) ---
        coverage: no_speech в тексте пользователя
        """)
        XCTAssertEqual(SecretaryPacketFiles.attention(header), ["перерасшифровка: no_speech", "coverage: ~6 s text for 139 s audio"])
    }

    func testUtf8PagingReassemblesEveryByteAndNeverAcknowledgesSource() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let path = URL(fileURLWithPath: m["sources"] as! String).appendingPathComponent("S1.txt")
        let expected = try Data(contentsOf: path)
        var offset = 0, assembled = Data()
        repeat {
            let page = try read(id, "source", "S1", offset: offset, limit: 17)
            let text = try XCTUnwrap(page["text"] as? String)
            XCTAssertFalse(text.contains("\u{FFFD}"))
            XCTAssertLessThanOrEqual(text.utf8.count, 17)
            assembled.append(Data(text.utf8))
            guard let next = page["next_offset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset); offset = next
        } while true
        XCTAssertEqual(assembled, expected)
        XCTAssertTrue(marks.marks().isEmpty)
        XCTAssertThrowsError(try read(id, "source", "S1", offset: expected.count + 1))
        XCTAssertThrowsError(try read(id, "source", "S1", limit: 0))
    }

    func testRepeatedSectionReadReturnsExistingBlocksAndWorkspaceChangesFailClosed() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let first = try read(id, "section", "Маяк"), second = try read(id, "section", "Маяк")
        let texts = { (value: [String: Any]) in (value["document_blocks"] as? [[String: String]])?.compactMap { $0["text"] } }
        XCTAssertEqual(texts(first), texts(second)); XCTAssertFalse(texts(first)?.isEmpty ?? true)
        try "new user edit".write(to: document, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try read(id, "section", "Маяк"))
        do { _ = try await SecretaryPacketFiles.apply(runID: id, response: response(m), marks: marks, recordings: { self.files }); XCTFail("stale workspace accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("workspace/policy changed")) }
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "new user edit")
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testRefreshRendersNewVersionAndRetainsAllVariantsWithoutIncreasingBudget() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: files[0])) {
            $0["transcription"] = ["transcript": "Fresh cloud text", "provider": "gemini", "localTranscript": "Different realtime text",
                                   "previousRuns": [["transcript": "Older local text", "provider": "parakeet"]]]; return true
        }
        _ = try read(id, "source", "S1", refresh: true)
        let exported = try String(contentsOf: URL(fileURLWithPath: m["sources"] as! String).appendingPathComponent("S1.txt"), encoding: .utf8)
        XCTAssertTrue(exported.contains("Fresh cloud text")); XCTAssertTrue(exported.contains("Different realtime text"))
        XCTAssertTrue(exported.contains("Older local text"))
        let preview = try object(await SecretaryPacketFiles.apply(runID: id, response: response(m), dryRun: true, marks: marks))
        XCTAssertEqual((preview["edits"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(preview["accepted"] as? Bool, true)
        try String(repeating: "large", count: 20_000).write(to: files[0], atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try read(id, "source", "S1", refresh: true))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: m["sources"] as! String).appendingPathComponent("S1.txt"), encoding: .utf8), exported)
    }

    func testEditedWorkspaceExportsCannotAuthorizeEditsOrChangeReceipts() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let body = try response(m)
        try "{}".write(to: URL(fileURLWithPath: m["input"] as! String), atomically: true, encoding: .utf8)
        try "FAKE".write(to: URL(fileURLWithPath: m["sources"] as! String).appendingPathComponent("S1.txt"), atomically: true, encoding: .utf8)
        let page = try read(id, "source", "S1")
        XCTAssertTrue((page["text"] as! String).contains("Источник")); XCTAssertFalse((page["text"] as! String).contains("FAKE"))
        let result = try object(await SecretaryPacketFiles.apply(runID: id, response: body, marks: marks, recordings: { self.files }))
        XCTAssertEqual(result["stored_sources"] as? [String], ["S1", "S2"])
        XCTAssertEqual(marks.marks().count, 2)
    }

    func testPrivateModeRejectsStoredTextAndApplyBeforeMutation() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let old = ProcessInfo.processInfo.environment["WIMM_PRIVATE_MODE"]
        setenv("WIMM_PRIVATE_MODE", "1", 1)
        defer { if let old { setenv("WIMM_PRIVATE_MODE", old, 1) } else { unsetenv("WIMM_PRIVATE_MODE") } }
        XCTAssertThrowsError(try read(id, "source", "S1"))
        XCTAssertThrowsError(try SecretaryPacketFiles.sessionSnapshot(runID: id, marks: marks))
        XCTAssertThrowsError(try SecretaryPacketFiles.checkpointSnapshot(file: root.appendingPathComponent("unused.json.lzfse")))
        do { _ = try await SecretaryPacketFiles.apply(runID: id, response: Data("{}".utf8), marks: marks); XCTFail("private apply accepted") }
        catch { XCTAssertEqual(error as? SecretaryError, .privateMode) }
        do { _ = try await SecretaryPacketFiles.warm(cli: URL(fileURLWithPath: "/unused")); XCTFail("private warm accepted") }
        catch { XCTAssertEqual(error as? SecretaryError, .privateMode) }
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testCachedContextReadsDoNotRewriteExportsOrStateAndRecordTimings() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let exported = URL(fileURLWithPath: m["input"] as! String).deletingLastPathComponent()
        let state = marks.directory.appendingPathComponent("SecretaryFileSessions/\(id).json")
        let paths = ["input.json", "manifest.json", "policy.md", "response.schema.json", "sources/S1.txt", "sources/S2.txt"].map { exported.appendingPathComponent($0) } + [state]
        let old = Date(timeIntervalSince1970: 1234)
        for path in paths { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path) }
        let inodes = try paths.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as! NSNumber }
        for (op, query) in [("outline", ""), ("section", "Маяк"), ("find", "Старый факт")] {
            let result = try read(id, op, query)
            let timing = try XCTUnwrap(result["timings_ms"] as? [String: Double])
            XCTAssertGreaterThanOrEqual(timing["total"]!, 0)
            XCTAssertEqual((result["work_counts"] as! [String: Int])["export_files_written"] ?? 0, 0)
            XCTAssertNil((result["work_counts"] as! [String: Int])["library_note_count"])
        }
        for (index, path) in paths.enumerated() {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, old, path.path)
            XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, inodes[index], path.path)
        }
        let traces = try FileManager.default.contentsOfDirectory(at: marks.directory.appendingPathComponent("SecretaryFileSessions/\(id).timings"), includingPropertiesForKeys: nil)
        XCTAssertEqual(traces.count, 4) // prepare plus three reads
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testAdmittingDocumentContextWritesOnlyInputAndManifest() async throws {
        let original = try String(contentsOf: document, encoding: .utf8)
        let padding = (0..<60).map { "Paragraph \($0) " + String(repeating: "background ", count: 80) + "\n\n" }.joined()
        try (original + padding + "## Far section\n\nUnique distant evidence.\n\n").write(to: document, atomically: true, encoding: .utf8)
        let m = try await prepare(), id = m["run_id"] as! String
        let result = try read(id, "section", "Far section")
        XCTAssertTrue((result["document_blocks"] as! [[String: String]]).contains { $0["text"]!.contains("Unique distant") })
        XCTAssertEqual((result["work_counts"] as! [String: Int])["export_files_written"], 2)
        let again = try read(id, "section", "Far section")
        XCTAssertNil((again["work_counts"] as! [String: Int])["export_files_written"])
    }

    func testAddressedRefreshBuildsOneNoteAndWritesOnlyItsSource() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let state = try SecretaryPacketFiles.load(id, marks: marks)
        // An unrelated malformed sidecar must not be parsed during refresh.
        try "not json".write(to: root.appendingPathComponent("recordings/unrelated.meta.json"), atomically: true, encoding: .utf8)
        try "Refreshed typed text".write(to: files[0], atomically: true, encoding: .utf8)
        let one = try await SecretaryPacketFiles.libraryForRefresh(state, source: "S1")
        XCTAssertEqual(one.count, 1); XCTAssertEqual(one[0].filePath, files[0].path)
        let result = try object(SecretaryPacketFiles.read(runID: id, operation: "source", query: "S1", refresh: true, library: one, marks: marks))
        XCTAssertTrue((result["text"] as! String).contains("Refreshed typed text"))
        XCTAssertEqual((result["work_counts"] as! [String: Int])["export_files_written"], 3)
        do { _ = try await SecretaryPacketFiles.libraryForRefresh(state, source: "S999"); XCTFail("unknown source accepted") } catch {}
        try FileManager.default.removeItem(at: files[0])
        do { _ = try await SecretaryPacketFiles.libraryForRefresh(state, source: "S1"); XCTFail("missing source accepted") } catch {}
    }

    func testRefreshAcceptsCanonicalPathAliasButRefusesEscapingMediaSymlink() async throws {
        let m = try await prepare(), id = m["run_id"] as! String
        let state = try SecretaryPacketFiles.load(id, marks: marks)
        let alias = root.appendingPathComponent("recordings-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("recordings"))
        let original = library[0]
        let aliased = RecallNote(id: original.id, date: original.date, kind: original.kind, title: original.title,
            summary: original.summary, text: original.text, filePath: alias.appendingPathComponent(files[0].lastPathComponent).path)
        let refreshed = try state.packet().refreshingSource("S1", library: RecallLibrary([aliased]), sourceLimit: 64_000)
        XCTAssertTrue(refreshed.receipts[0].allAvailableTextSupplied)
        let outside = root.appendingPathComponent("outside.txt")
        try "Must not be read".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: files[0])
        try FileManager.default.createSymbolicLink(at: files[0], withDestinationURL: outside)
        do {
            _ = try await SecretaryPacketFiles.libraryForRefresh(state, source: "S1")
            XCTFail("escaping media symlink accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("outside its owned library")) }
    }

    func testFlaggedSourceIsExplicitlyBlockedWithoutStoppingIndependentPacket() async throws {
        var value = try object(Data(contentsOf: registry))
        var rows = value["sources"] as! [[String: Any]]
        rows[0]["wimm_unindexed"] = "Original media missing; attachment is not the original"
        value["sources"] = rows
        let original = try JSONSerialization.data(withJSONObject: value)
        try original.write(to: registry)
        let manifest = try await prepare()
        XCTAssertEqual(manifest["source_ids"] as? [String], ["S2"])
        XCTAssertEqual((manifest["blocked_sources"] as! [[String: String]]).map { $0["source"]! }, ["S1"])
        XCTAssertEqual(try Data(contentsOf: registry), original)
        XCTAssertTrue(marks.marks().isEmpty)
        let input = try object(Data(contentsOf: URL(fileURLWithPath: manifest["input"] as! String)))
        XCTAssertEqual(input["remaining"] as? Int, 1)
        XCTAssertNil(input["blocked_sources"], "the model input never lists unadmitted sources")
        rows[1]["removed_from_wimm"] = true; value["sources"] = rows
        try JSONSerialization.data(withJSONObject: value).write(to: registry)
        do { _ = try await prepare(); XCTFail("all-blocked queue reported as an empty queue") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Nothing acknowledged")) }
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testEditorBundleRetainsEveryTypedBlockAndSharesOnlyExactBytes() async throws {
        for file in files { try "Same exact body. Ёж 🦔\n".write(to: file, atomically: true, encoding: .utf8) }
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: files[0])) {
            $0["transcription"] = ["transcript": "No, not agreed.", "localTranscript": "No not agreed!",
                "provider": "gemini", "previousRuns": [["transcript": "Agreed? No.", "provider": "parakeet"]]]; return true
        }
        let bundle = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 64, library: library, marks: marks, editorBundle: true))
        let pooled = Dictionary(uniqueKeysWithValues: (bundle["texts"] as! [[String: String]]).map { ($0["id"]!, $0["text"]!) })
        let sources = bundle["sources"] as! [[String: Any]]
        let suppliedLibrary = library
        XCTAssertEqual(sources.count, 2); XCTAssertNotNil(bundle["context_coverage"])
        for source in sources {
            let i = Int((source["source"] as! String).dropFirst())! - 1
            var expected: [MCPRecallServer.EvidenceBlock] = []
            _ = MCPRecallServer(marks: marks, library: { suppliedLibrary }).readNote(suppliedLibrary[i], full: true, format: .secretaryPacket,
                evidence: { _, blocks in expected = blocks })
            let refs = source["evidence"] as! [[String: Any]]
            XCTAssertEqual(refs.count, expected.count)
            for (ref, block) in zip(refs, expected) {
                XCTAssertEqual(ref["label"] as? String, block.label)
                XCTAssertEqual(Data(pooled[ref["text_ref"] as! String]!.utf8), Data(block.text.utf8))
            }
        }
        let storage = bundle["evidence_storage"] as! [String: Int]
        XCTAssertLessThan(storage["unique_block_bytes"]!, storage["original_block_bytes"]!)
        for variant in ["No, not agreed.", "No not agreed!", "Agreed? No."] { XCTAssertTrue(pooled.values.contains(variant)) }
        XCTAssertTrue(marks.marks().isEmpty)
    }
}
