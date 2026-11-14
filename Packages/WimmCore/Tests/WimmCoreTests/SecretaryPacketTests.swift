import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryPacketTests: XCTestCase {
    private static var canonicalJSONEncoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }

    private var root: URL!
    private var store: AgentMarkStore!
    private var media: URL { root.appendingPathComponent("recordings/note.txt") }
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registry: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }
    private var task: SecretaryTask {
        SecretaryTask(id: "packet-test", kind: .pass, workspace: SecretaryWorkspace(document: document)!, threads: [],
            wimmCLI: "/usr/bin/true", createdAt: Date(), packetMode: true)
    }
    private var library: RecallLibrary {
        RecallLibrary([RecallNote(id: "note", date: Date(), kind: "text", title: "Проект Маяк", summary: nil,
            text: "stale cache must not be used", filePath: media.path, updated: Date())])
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("packet-test-\(UUID().uuidString)")
        for name in ["recordings", "docs", "secretary/protocol", "secretary/runs/packet-test"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        store = AgentMarkStore(directory: root.appendingPathComponent("state"))
        try "Маяк: экспорт Markdown пока только план. Срок 30 октября, 15:00.".write(to: media, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: media)) { $0["recordingId"] = "note"; return true }
        try "# Документ\n\nСводка: проект Маяк [S1].\n\n## Маяк\n\nСтарый факт: запуск 12 октября [S1].\n\n[S1]: ../recordings/note.meta.json\n".write(to: document, atomically: true, encoding: .utf8)
        try "# Источники\nСохранять даты и отличать планы от событий.".write(to: root.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\n- Q9. Старый вопрос.\n\n## Разрешено\n".write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        try writeRegistry(sources: [["source_id": "S1", "path": "../recordings/note.meta.json", "note_file": "note.txt", "status": "pending", "reason": "old", "opaque": ["keep": true]]])
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func writeRegistry(sources: [[String: Any]]) throws {
        var counts: [String: Int] = [:]
        for source in sources { counts[source["status"] as! String, default: 0] += 1 }
        try JSONSerialization.data(withJSONObject: ["sources": sources, "source_count": sources.count, "counts": counts, "batches": [["original": true]]]).write(to: registry)
    }
    private func prepare(sourceLimit: Int = 64_000, docLimit: Int = 24_000) throws -> SecretaryPacket {
        try SecretaryPacket.prepare(task: task, library: library, marks: store, sourceByteLimit: sourceLimit, documentByteLimit: docLimit)
    }
    private func plan(_ packet: SecretaryPacket, edit: SecretaryPacket.Edit? = nil, status: String = "pending", questions: [String] = [], needs: [String] = []) -> SecretaryPacket.Plan {
        .init(summary: "Проверил источник", sourceDecisions: packet.selected.map { .init(source: $0, status: status, reason: "План, ещё не исполнено") }, edits: edit.map { [$0] } ?? [], questions: questions, needsContext: needs)
    }

    func testExplicitUserHoldSkipsWholeSourceWithoutReceiptAndReleaseRestoresIt() throws {
        let hold: [String: Any] = ["active": true, "authority": "user", "scope": "source",
            "resume": "explicit_user_release", "reason": "Temporarily ignore these screenshots"]
        let row: [String: Any] = ["source_id": "S1", "path": "../recordings/note.meta.json",
            "note_file": "note.txt", "status": "noise", "reason": "user request", "user_exclusion": hold]
        try writeRegistry(sources: [row])
        XCTAssertThrowsError(try prepare()) { XCTAssertTrue($0.localizedDescription.contains("explicitly held")) }
        XCTAssertTrue(store.marks().isEmpty)
        var released = row, inactive = hold; inactive["active"] = false; released["user_exclusion"] = inactive
        try writeRegistry(sources: [released])
        XCTAssertEqual(try prepare().selected, ["S1"])
        var malformed = hold; malformed["authority"] = "model"; released["user_exclusion"] = malformed
        try writeRegistry(sources: [released])
        XCTAssertEqual(try prepare().selected, ["S1"])
        var alias = row; alias["note_file"] = "another-image.heic"
        try writeRegistry(sources: [alias])
        XCTAssertEqual(try prepare().selected, ["S1"])
        let otherFile = root.appendingPathComponent("recordings/other.txt")
        try "Independent source".write(to: otherFile, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: otherFile)) { $0["recordingId"] = "other"; return true }
        try writeRegistry(sources: [row, ["source_id": "S2", "path": "../recordings/other.meta.json",
            "note_file": "other.txt", "status": "pending", "reason": "unread"]])
        let other = RecallNote(id: "other", date: Date(), kind: "text", title: nil, summary: nil,
                              text: "cache", filePath: otherFile.path, updated: Date())
        let independent = try SecretaryPacket.prepare(task: task, library: RecallLibrary([library[0], other]), marks: store)
        XCTAssertEqual(independent.selected, ["S2"])
        XCTAssertNil(independent.fullSourcesByID["S1"])
        XCTAssertEqual(independent.receipts.count, 1)
        XCTAssertEqual((independent.payload["held_sources"] as? [[String: String]])?.first?["source"], "S1")
        // Host bookkeeping only: the model input never lists unadmitted sources.
        let modelInput = try JSONSerialization.jsonObject(with: Data(independent.prompt().utf8)) as! [String: Any]
        XCTAssertNil(modelInput["held_sources"]); XCTAssertNil(modelInput["blocked_sources"])
    }

    func testPacketHasFreshFullTextRegistryAndBoundedDocumentWithoutWritingMarks() throws {
        let before = try Data(contentsOf: registry)
        let packet = try prepare()
        let input = try packet.prompt()
        XCTAssertTrue(input.contains("Markdown")); XCTAssertTrue(input.contains("30 октября"))
        XCTAssertFalse(input.contains("stale cache")); XCTAssertFalse(input.contains("opaque"))
        XCTAssertEqual(packet.selected, ["S1"])
        XCTAssertTrue(store.marks().isEmpty)
        XCTAssertEqual(try Data(contentsOf: registry), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SecretaryReadReceipt.logURL(runID: task.id, store: store).path))
    }

    func testCompactPacketRenderingPreservesLiteralBodyAndActualCoverage() throws {
        let body = "Я не согласился на 460 евро.\nfile: literal user text\nsha256: literal user text\n--- visual source roster is a literal sentence\nРешение ещё не принято."
        try body.write(to: media, atomically: true, encoding: .utf8)
        let notes = library
        let server = MCPRecallServer(marks: store, library: { notes })
        let standard = server.readNote(library[0], full: true, format: .secretaryPacketWithMetadata)
        let compact = server.readNote(library[0], full: true, format: .secretaryPacket)
        XCTAssertTrue(standard.text.contains("file: \(media.path)"))
        XCTAssertFalse(compact.text.contains("file: \(media.path)"))
        XCTAssertTrue(compact.text.contains(body))
        XCTAssertFalse(compact.text.contains("title_source:"), "packet reads carry no title/summary")
        XCTAssertLessThan(compact.text.utf8.count, standard.text.utf8.count)
        let original = try XCTUnwrap(standard.receipt), supplied = try XCTUnwrap(compact.receipt)
        XCTAssertEqual(original.sha256, supplied.sha256)
        XCTAssertEqual(original.text, supplied.text)
        XCTAssertEqual(try Self.canonicalJSONEncoder.encode(original.suppliedText), try Self.canonicalJSONEncoder.encode(supplied.suppliedText))
        XCTAssertTrue(supplied.allAvailableTextSupplied)
        let packet = try prepare()
        XCTAssertEqual(packet.fullSourcesByID["S1"], compact.text)
        XCTAssertTrue(packet.projectedSourceIDs.isEmpty)
        XCTAssertNoThrow(try packet.requireValidatedProjection())

        let filtered = try SecretaryPacket.prepare(task: task, library: library, marks: store, optimizationLevel: .l1)
        let filteredText = try XCTUnwrap(filtered.fullSourcesByID["S1"])
        XCTAssertTrue(server.readNote(library[0], full: true).text.hasPrefix("id: \(library[0].id)\n"))
        XCTAssertFalse(filteredText.contains("id: \(library[0].id)\n"))
        XCTAssertEqual(filtered.receipts[0].noteID, library[0].id)
    }
    func testFilteredProjectionCannotReuseFullReceiptOrApplyChanges() throws {
        let body = "IMPORTANT BEGINNING: я не согласился. " + String(repeating: "Обычный текст. ", count: 200)
        try body.write(to: media, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: document)
        let packet = try SecretaryPacket.prepare(task: task, library: library, marks: store, optimizationLevel: .l5)
        XCTAssertEqual(packet.projectedSourceIDs, ["S1"])
        XCTAssertFalse(packet.receipts[0].allAvailableTextSupplied)
        XCTAssertNil(packet.receipts[0].suppliedText)
        XCTAssertEqual(packet.payload["source_text_truncated"] as? Bool, true)
        XCTAssertThrowsError(try packet.apply(plan(packet, status: "applied"), prompt: packet.prompt(), marks: store))
        XCTAssertEqual(try Data(contentsOf: document), before)
        XCTAssertTrue(store.marks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SecretaryReadReceipt.logURL(runID: task.id, store: store).path))
    }

    func testCompactImageReadOmitsOnlyHostRosterFromCoverage() throws {
        let image = root.appendingPathComponent("recordings/photo.jpg")
        try Data("fixture; no raster decoding needed".utf8).write(to: image)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: image)) {
            $0["recordingId"] = "photo"; return true
        }
        let note = RecallNote(id: "photo", date: Date(), kind: "image", title: nil, summary: nil,
                              text: "", filePath: image.path)
        let server = MCPRecallServer(marks: store, library: { RecallLibrary([note]) })
        let standard = server.readNote(note, full: true, format: .secretaryPacketWithMetadata)
        let compact = server.readNote(note, full: true, format: .secretaryPacket)
        XCTAssertTrue(standard.text.contains("use get_note_image"))
        XCTAssertFalse(compact.text.contains("use get_note_image"))
        let coverage = try XCTUnwrap(standard.receipt?.suppliedText)
        XCTAssertTrue(coverage.contains { $0.label.hasPrefix("visual source roster") })
        let expected = coverage.filter { !$0.label.hasPrefix("visual source roster") }
        XCTAssertEqual(try Self.canonicalJSONEncoder.encode(expected), try Self.canonicalJSONEncoder.encode(compact.receipt?.suppliedText))
        XCTAssertTrue(try XCTUnwrap(compact.receipt).allAvailableTextSupplied)
    }

    func testProjectedPassRefusesBeforeExecutorOrResultWrite() async throws {
        var dispatcher = SecretaryDispatcher(executor: PacketFakeExecutor(body: "must not be called", cost: 0.01),
                                             wimmCLI: URL(fileURLWithPath: "/cli"))
        dispatcher.optimizationLevel = .l1
        do {
            _ = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
            XCTFail("Projected sources cannot be acknowledged by an original full-read receipt")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Preview/offline benchmarks only")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.workspace.runDirectory(task.id).appendingPathComponent("packet-execution.json").path))
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testPacketKeepsStructuredImageEvidenceAndEarlierDescription() throws {
        var run = ImageBatchRecord(source:"/tmp/public-control.png",sourceSHA256:"IMAGE_HASH",engine:"mlx")
        run.vision = VisionImageAnalysis(ocrText:"VISUAL_LITERAL",scene:"NATIVE_SCENE",sceneObservation:nil,
            codes:[.init(symbology:"QR",payload:"CODE_PAYLOAD",confidence:0.8)],detectedData:[],isDenseDocument:false,documentEngine:"test",issues:[])
        run.caption = try LocalPhotoModel.decode(Data(#"{"caption":"EARLIER_DESCRIPTION","seconds":1,"peak_memory_gb":1,"generation_tokens":1,"finish_reason":"stop"}"#.utf8))
        var attachment: [String:Any] = ["id":UUID().uuidString,"type":"image"]
        try ImageAnalysisHistory.store(run,in:&attachment)
        run.caption = nil;run.engine = "vision"
        try ImageAnalysisHistory.store(run,in:&attachment)
        try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:media)) {
            $0["attachments"] = [attachment];return true
        }
        let packet = try prepare(), input = try packet.prompt()
        for part in ["VISUAL_LITERAL","NATIVE_SCENE","CODE_PAYLOAD","EARLIER_DESCRIPTION","IMAGE_HASH","model draft; not literal text"] {
            XCTAssertTrue(input.contains(part),part)
        }
        XCTAssertTrue(packet.receipts[0].allAvailableTextSupplied)
        XCTAssertTrue(packet.receipts[0].suppliedText?.contains { $0.label.contains("earlier run") && $0.label.contains("MLX description") } == true)
        let notes = library
        let server = MCPRecallServer(marks: store, library: { notes })
        let standard = server.readNote(library[0], full: true)
        let expected = try XCTUnwrap(standard.receipt?.suppliedText).filter { !$0.label.hasPrefix("visual source roster") }
        // Same blocks as the standard read; default image status blocks are listed, not printed.
        let supplied = try XCTUnwrap(packet.receipts[0].suppliedText)
        XCTAssertEqual(supplied.map(\.label), expected.map(\.label))
        for (packetBlock, standardBlock) in zip(supplied, expected) where packetBlock.state != standardBlock.state {
            XCTAssertEqual(packetBlock.state, "default_status", packetBlock.label)
        }
        XCTAssertFalse(input.contains("use get_note_image"))
    }
    func testOversizedSourceFailsWithoutTruncatingOrMarking() throws {
        let packet = try prepare(sourceLimit: 10)
        XCTAssertEqual(packet.selected, [])
        let blocked = packet.payload["blocked_sources"] as? [[String: String]] ?? []
        XCTAssertEqual(blocked.map { $0["source"] }, ["S1"])
        XCTAssertTrue(store.marks().isEmpty)
    }
    func testVisualRequestCannotApplyOrAcknowledgeTextOnlyPacket() throws {
        let packet=try prepare()
        var result=plan(packet,status:"applied")
        result.needsImages=["S1"]
        let before=try Data(contentsOf:document)
        XCTAssertThrowsError(try packet.apply(result,prompt:packet.prompt(),marks:store))
        XCTAssertEqual(try Data(contentsOf:document),before)
        XCTAssertTrue(store.marks().isEmpty)
    }
    func testLongFirstSourceGetsCompleteSoloPacketWithoutSkippingIt() throws {
        let body = String(repeating: "x", count: 70_000) + "COMPLETE TAIL"
        try body.write(to: media, atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("recordings/next.txt")
        try "Next short note".write(to: other, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: other)) { $0["recordingId"] = "next"; return true }
        let queued = RecallLibrary([library[0], RecallNote(id: "next", date: Date(), kind: "text", title: nil, summary: nil,
            text: "Next short note", filePath: other.path, updated: Date().addingTimeInterval(-60))])
        let packet = try SecretaryPacket.prepare(task: task, library: queued, marks: store, sourceByteLimit: 64_000)
        XCTAssertEqual(packet.selected, ["S1"])
        XCTAssertTrue(packet.newSources.isEmpty)
        XCTAssertEqual(packet.payload["remaining"] as? Int, 1)
        XCTAssertEqual(packet.payload["solo_large_source"] as? Bool, true)
        XCTAssertTrue(try packet.prompt().contains("COMPLETE TAIL"))
        XCTAssertFalse(try packet.prompt().contains("[truncated,"))
        XCTAssertTrue(store.marks().isEmpty)
    }
    func testSourceBeyondSoloLimitIsReportedAndDoesNotBlockTheQueue() throws {
        try String(repeating: "x", count: 130_000).write(to: media, atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("recordings/next.txt")
        try "Next short note".write(to: other, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: other)) { $0["recordingId"] = "next"; return true }
        let queued = RecallLibrary([library[0], RecallNote(id: "next", date: Date(), kind: "text", title: nil, summary: nil,
            text: "Next short note", filePath: other.path, updated: Date().addingTimeInterval(-60))])
        let packet = try SecretaryPacket.prepare(task: task, library: queued, marks: store, sourceByteLimit: 64_000)
        XCTAssertEqual(packet.selected.count, 1)
        XCTAssertNotEqual(packet.selected, ["S1"])
        let blocked = packet.payload["blocked_sources"] as? [[String: String]] ?? []
        XCTAssertEqual(blocked.map { $0["source"] }, ["S1"])
        XCTAssertTrue(blocked[0]["reason"]?.contains("solo packet limit") == true)
        let previews = packet.payload["oversize_previews"] as? [[String: Any]] ?? []
        XCTAssertEqual(previews.compactMap { $0["source"] as? String }, ["S1"])
        XCTAssertTrue(store.marks().isEmpty)
    }
    func testSourceBeyondSoloLimitIsBlockedBeforeAnyWrite() throws {
        try String(repeating: "x", count: 130_000).write(to: media, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: registry)
        let packet = try prepare()
        XCTAssertEqual(packet.selected, [])
        let blocked = packet.payload["blocked_sources"] as? [[String: String]] ?? []
        XCTAssertEqual(blocked.map { $0["source"] }, ["S1"])
        XCTAssertEqual(try Data(contentsOf: registry), before)
        XCTAssertTrue(store.marks().isEmpty)
    }
    func testDefaultBudgetKeepsLargeSourceAndFullExpansion() throws {
        try (String(repeating: "x", count: 400_000) + "FULL_END").write(to: media, atomically: true, encoding: .utf8)
        let packet = try SecretaryPacket.prepare(task: task, library: library, marks: store)
        XCTAssertEqual(packet.selected, ["S1"])
        XCTAssertEqual(packet.payload["solo_large_source"] as? Bool, false)
        XCTAssertTrue(try packet.prompt(extra: ["full:S1"]).contains("FULL_END"))
        XCTAssertTrue(packet.receipts.allSatisfy(\.allAvailableTextSupplied))
    }

    func testByteBudgetCanSelectMoreThanTwentyCompleteNotes() throws {
        var notes = [library[0]]
        for i in 1...24 {
            let file = root.appendingPathComponent("recordings/extra-\(i).txt")
            try "Complete note \(i)".write(to: file, atomically: true, encoding: .utf8)
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) {
                $0["recordingId"] = "extra-\(i)"; return true
            }
            notes.append(RecallNote(id: "extra-\(i)", date: Date(), kind: "text", title: nil, summary: nil,
                                    text: "", filePath: file.path, updated: Date()))
        }
        let packet = try SecretaryPacket.prepare(task: task, library: RecallLibrary(notes), marks: store)
        XCTAssertEqual(packet.selected.count, 25)
        XCTAssertEqual(packet.payload["remaining"] as? Int, 0)
        XCTAssertTrue(packet.receipts.allSatisfy(\.allAvailableTextSupplied))
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testCodexPacketUsesReadOnlyNoToolsAndNoMCP() {
        var request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "DATA", kind: .pass,
            wimmCLI: "/cli", budgetUSD: 2, model: "gpt-x", timeout: 60, effort: "medium")
        request.systemPrompt = "policy"
        let args = CodexExecutor(binary: URL(fileURLWithPath: "/codex")).arguments(for: request, lastMessage: root.appendingPathComponent("last.txt"))
        XCTAssertEqual(args[args.firstIndex(of: "-s")! + 1], "read-only")
        XCTAssertTrue(args.contains("features.shell_tool=false"))
        XCTAssertTrue(args.contains("forced_login_method=\"chatgpt\""))
        XCTAssertTrue(args.contains("features.view_image=false"))
        XCTAssertTrue(args.contains("skills.include_instructions=false"))
        XCTAssertTrue(args.contains("skills.bundled.enabled=false"))
        XCTAssertTrue(args.contains("features.sleep_tool=false"))
        XCTAssertTrue(args.contains("features.plugins=false"))
        XCTAssertTrue(args.contains("agents.enabled=false"))
        XCTAssertTrue(args.contains("project_doc_max_bytes=0"))
        XCTAssertTrue(args.contains { $0.hasPrefix("model_instructions_file=") })
        XCTAssertFalse(args.joined().contains("mcp_servers"))
        XCTAssertFalse(args.contains("DATA"))
        XCTAssertEqual(args.last, "-")
    }

    func testCodexFullPassOptsIntoWorkspacePacketPolicy() async throws {
        let dispatcher = SecretaryDispatcher(executor: CodexExecutor(binary: URL(fileURLWithPath: "/codex")),
                                             wimmCLI: URL(fileURLWithPath: "/cli"))
        let prepared = try await dispatcher.preparePass(document: document, force: true)
        XCTAssertTrue(prepared.packetMode)
    }

    func testDispatcherUsesSelectedBudgetAndAcceptsCompleteResponseWithUnknownCost() async throws {
        try String(repeating: "x", count: 400_000).write(to: media, atomically: true, encoding: .utf8)
        let body = #"{"summary":"Read","edits":[],"done_no_additions":[{"source":"S1","reason":"Needs review"}],"unfinished":[],"not_a_note":[],"questions":[]}"#
        var dispatcher = SecretaryDispatcher(executor: PacketFakeExecutor(body: body, cost: nil),
                                             wimmCLI: URL(fileURLWithPath: "/cli"))
        dispatcher.packetSourceKB = 64
        let blocked = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertTrue(blocked.isError, "A 400 KB source cannot fit the 64 KB budget or its solo exception")
        XCTAssertTrue(store.marks().isEmpty)
        dispatcher.packetSourceKB = 512
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertFalse(execution.isError)
        XCTAssertNil(execution.costUSD)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.workspace.runDirectory(task.id).appendingPathComponent("result.json").path))
        XCTAssertTrue(store.marks().isEmpty, "Only the outer verified run finalizes marks")
    }

    func testEmptyNoneInvokePrefixIsDecodedWithoutAnotherModelRequest() throws {
        let json = #"{"summary":"Прочитано","edits":[],"done_no_additions":[],"unfinished":[],"not_a_note":[],"questions":[]}"#
        let plan = try SecretaryPacket.decodeEdits("```json\n" + json + "\n```")
        XCTAssertEqual(plan.summary, "Прочитано")
        let plainPlan = try SecretaryPacket.decodeEdits(json)
        XCTAssertEqual(plainPlan.summary, "Прочитано")
        XCTAssertThrowsError(try SecretaryPacket.decodeEdits("plain text without json"))
    }
    func testPacketRecognizesOwnedDirectoryCaseAliases() throws {
        let alias = root.appendingPathComponent("Recordings/note.txt")
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("case-sensitive filesystem") }
        let aliased = RecallLibrary([RecallNote(id: "note", date: Date(), kind: "text", title: nil, summary: nil,
            text: "cached", filePath: alias.path, updated: Date())])
        XCTAssertEqual(try SecretaryPacket.prepare(task: task, library: aliased, marks: store).selected, ["S1"])
    }
    func testOldResolvedQuestionHistoryDoesNotInflatePacket() throws {
        let queue = "## Открытые вопросы\n\nQ1. Сейчас?\n\n## Разрешено\n\n" + String(repeating: "Старый вопрос. ", count: 5000)
        try queue.write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        let packet = try prepare()
        XCTAssertTrue(packet.queueData.count > 24_000)
        let supplied = packet.payload["review_queue"] as! String
        XCTAssertTrue(supplied.contains("Q1.")); XCTAssertFalse(supplied.contains("Старый вопрос"))
    }
    func testPacketBypassesMCPTruncationAndKeepsPunctuationVariants() throws {
        let body = String(repeating: "x", count: 25_000) + "FULL TAIL"
        try body.write(to: media, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: media)) {
            $0["transcription"] = ["transcript": "Нет, надо.", "localTranscript": "Нет надо."]; return true
        }
        let input = try prepare().prompt()
        XCTAssertTrue(input.contains("FULL TAIL")); XCTAssertTrue(input.contains("Нет, надо.")); XCTAssertTrue(input.contains("Нет надо."))
        XCTAssertFalse(input.contains("[truncated,"))
    }
    func testPacketAppliesExactUnicodeBlockAndUsesExistingVersionChecks() async throws {
        let packet = try prepare()
        try SecretaryRegistryRevision.snapshot(packet.registryData, directory: task.workspace.runDirectory(task.id))
        let block = try XCTUnwrap(packet.blocks.first { $0.text.contains("Старый факт") })
        let edit = SecretaryPacket.Edit(block: block.id, text: block.text + "Экспорт Markdown — план; проверка 30 октября в 15:00 [S1].\n\n")
        let result = try packet.apply(plan(packet, edit: edit, status: "applied", questions: ["Каков результат проверки?"]), prompt: packet.prompt(), marks: store)
        let text = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(text.contains("Старый факт: запуск 12 октября")); XCTAssertTrue(text.contains("Markdown"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("secretary/review_queue.md"), encoding: .utf8).contains("Q10."))
        let media = media
        let report = await SecretaryBookkeeping.finish(task: task, result: result, store: store, recordings: { [media] })
        XCTAssertEqual(report.findings, []); XCTAssertEqual(report.stored, 1)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [String: Any]
        XCTAssertNotNil((value["sources"] as! [[String: Any]])[0]["opaque"])
    }
    func testChangedSourceOrWorkspaceCannotBeAcknowledged() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let before = try Data(contentsOf: document)
        try "human edit after packet".write(to: media, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try packet.apply(plan(packet), prompt: prompt, marks: store))
        XCTAssertEqual(try Data(contentsOf: document), before); XCTAssertTrue(store.marks().isEmpty)
        let next = try prepare()
        try "new document".write(to: document, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try next.apply(plan(next), prompt: next.prompt(), marks: store))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "new document")
    }
    func testUnknownBlocksCitationsAndMissingDecisionsFailBeforeWrites() throws {
        let packet = try prepare(), prompt = try packet.prompt(), before = try Data(contentsOf: document)
        XCTAssertThrowsError(try packet.apply(plan(packet, edit: .init(block: "b999", text: "oops")), prompt: prompt, marks: store))
        let block = packet.blocks[0]
        XCTAssertThrowsError(try packet.apply(plan(packet, edit: .init(block: block.id, text: "Unknown [S999].")), prompt: prompt, marks: store))
        let missing = SecretaryPacket.Plan(summary: "empty", sourceDecisions: [], edits: [], questions: [], needsContext: [])
        XCTAssertThrowsError(try packet.apply(missing, prompt: prompt, marks: store))
        XCTAssertEqual(try Data(contentsOf: document), before)
    }
    func testContextRequestDoesNotWriteAndExpansionIsBounded() throws {
        let packet = try prepare(docLimit: 80), before = try Data(contentsOf: document)
        XCTAssertThrowsError(try packet.apply(plan(packet, needs: ["Маяк"]), prompt: packet.prompt(), marks: store))
        let expanded = try packet.prompt(extra: ["Маяк"])
        XCTAssertTrue(expanded.contains("Старый факт")); XCTAssertTrue(expanded.contains("context_expansion"))
        XCTAssertEqual(try Data(contentsOf: document), before); XCTAssertTrue(store.marks().isEmpty)
    }
    func testContextExpansionFindsShortNamesOutsideInitialSelection() throws {
        let original = try String(contentsOf: document, encoding: .utf8)
        let filler = (0..<100).map { "## Область \($0)\n\nПрежний фон без связи с источником.\n\n" }.joined()
        try (original + filler + "## Люди\n\nИван Петров — старый знакомый.\n\n").write(to: document, atomically: true, encoding: .utf8)
        let packet = try prepare(docLimit: 1000)
        XCTAssertFalse(try packet.prompt().contains("Иван Петров —"))
        XCTAssertTrue(try packet.prompt(extra: ["Иван"]).contains("Иван Петров —"))
    }
    func testCitationContextOutranksUnrelatedBoilerplate() {
        let blocks = SecretaryPacket.blocks("# Документ\n\n" + String(repeating: "Ненужный общий фон.\n\n", count: 50)
            + "## Нужная тема\n\nСущественный старый факт [S42].\n\n")
        let selected = SecretaryPacket.select(blocks: blocks, sourceIDs: ["S42"], terms: [], limit: 160)
        XCTAssertTrue(selected.contains { $0.text.contains("Существенный старый факт") })
    }

    func testHeadingRequestIncludesBodyThroughSubheadings() {
        let text = "# Документ\n\n## Люди\n\nВводная.\n\n### Давид\n\nБлизкий родственник.\n\n### Иван\n\nКоллега.\n\n## Работа\n\nЧужая тема.\n\n"
        let blocks = SecretaryPacket.blocks(text)
        let selected = SecretaryPacket.select(blocks: blocks, sourceIDs: [], terms: [], limit: 240,
            phrases: ["Люди — действующие содержательные абзацы о знакомых"])
        XCTAssertTrue(selected.contains { $0.text.contains("Близкий родственник") })
        XCTAssertTrue(selected.contains { $0.text.contains("Коллега") })
    }

    func testExpansionBudgetDoesNotCountAlreadySuppliedBlocks() {
        let blocks = SecretaryPacket.blocks("# Документ\n\n## Люди\n\nДавид — родственник.\n\nИван — коллега.\n\n")
        let existing = Set(blocks.prefix(2).map(\.id))
        let remaining = blocks.dropFirst(2).reduce(0) { $0 + $1.text.utf8.count }
        let selected = SecretaryPacket.select(blocks: blocks, sourceIDs: [], terms: [], limit: remaining,
            phrases: ["Люди — все содержательные абзацы"], excluding: existing)
        XCTAssertEqual(Set(selected.map(\.id)), Set(blocks.dropFirst(2).map(\.id)))
    }

    func testAnchorHeadingAndShortTopicNamesRetrieveWholeSection() {
        let text = "# Документ\n\n<a id=\"wimm\"></a>\n## Wimm и личный помощник\n\nПервая часть.\n\n### Ранняя история\n\nВторая часть.\n\n## Другое\n\nЧужие сведения.\n\n"
        let blocks = SecretaryPacket.blocks(text)
        XCTAssertEqual(blocks.map(\.text).joined(), text)
        XCTAssertEqual(blocks.first { $0.text.contains("Первая часть") }?.section, "## Wimm и личный помощник")
        let result = SecretaryPacket.contextSelection(blocks: blocks, requests: ["Wimm: май–июль 2026"], existing: [], limit: 1000)
        XCTAssertTrue(result.blocks.contains { $0.text.contains("Вторая часть") })
        XCTAssertFalse(result.blocks.contains { $0.text.contains("Чужие сведения") })
    }

    func testEmbeddedReferencesAndShortNamesFindDocumentMentionsWithoutDefinitions() {
        let blocks = SecretaryPacket.blocks("# Документ\n\n## Рецепты\n\nРецепт пирога [S195] [S196].\n\n## Wimm\n\nСинхронизация приложения.\n\n[S195]: private/path\n[S196]: other/path\n\n")
        let result = SecretaryPacket.contextSelection(blocks: blocks,
            requests: ["Кулинария: S195 S196", "Wimm: синхронизация"], existing: [], limit: 1000)
        XCTAssertTrue(result.blocks.contains { $0.text.contains("Рецепт пирога") })
        XCTAssertTrue(result.blocks.contains { $0.text.contains("Синхронизация приложения") })
        XCTAssertFalse(result.blocks.contains { $0.text.contains("private/path") })
        XCTAssertEqual(result.reports[0].referencedSources, ["S195", "S196"])
        let initial = SecretaryPacket.select(blocks: blocks, sourceIDs: ["S195"], terms: [], limit: 1000)
        XCTAssertFalse(initial.contains { $0.text.contains("private/path") })
    }

    func testExpansionSharesBudgetAndNeverAdmitsBareHeadingWhenBodyDoesNotFit() {
        let text = "## Wimm\n\n" + String(repeating: "Большая тема. ", count: 50) + "\n\n## Кулинарные материалы\n\nРецепт пирога.\n\n"
        let result = SecretaryPacket.contextSelection(blocks: SecretaryPacket.blocks(text),
            requests: ["Wimm: история; Кулинарные материалы"], existing: [], limit: 120)
        XCTAssertTrue(result.blocks.contains { $0.text.contains("Рецепт пирога") })
        XCTAssertFalse(result.blocks.contains { $0.text.contains("## Wimm") })
        XCTAssertEqual(result.reports[0].status, "partial")
        XCTAssertFalse(result.reports[0].omittedForBudget.isEmpty)
        XCTAssertLessThanOrEqual(result.blocks.reduce(0) { $0 + $1.text.utf8.count }, 120)
    }

    func testExpansionReportsNotFoundAndAlreadySuppliedContext() throws {
        let blocks = SecretaryPacket.blocks("## Маяк\n\nИзвестный факт.\n\n")
        let result = SecretaryPacket.contextSelection(blocks: blocks, requests: ["Маяк", "НесуществующийГород"], existing: Set(blocks.map(\.id)), limit: 0)
        XCTAssertTrue(result.blocks.isEmpty)
        XCTAssertEqual(result.reports[0].status, "matched")
        XCTAssertEqual(result.reports[0].suppliedBlocks.count, 2)
        XCTAssertEqual(result.reports[1].status, "not_found")
        let packet = try prepare()
        let input = try JSONSerialization.jsonObject(with: Data(packet.prompt(extra: ["S943"]).utf8)) as! [String: Any]
        XCTAssertNotNil(input["context_report"])
        XCTAssertEqual((input["sources"] as? [[String: Any]])?.count, packet.selected.count)
        XCTAssertThrowsError(try packet.prompt(extra: ["full:S943"]))
    }

    func testNewSourceGetsStableIDAndHostMarksOnlyAfterDecision() async throws {
        try writeRegistry(sources: [])
        let packet = try prepare()
        XCTAssertEqual(packet.selected, ["S1"]); XCTAssertEqual(packet.newSources.count, 1)
        let result = try packet.apply(plan(packet), prompt: packet.prompt(), marks: store)
        let media = media
        let report = await SecretaryBookkeeping.finish(task: task, result: result, store: store, recordings: { [media] })
        XCTAssertEqual(report.findings, []); XCTAssertEqual(report.stored, 1)
        XCTAssertEqual(store.mark(forFile: "note.txt")?.status, .pending)
    }
    func testInvalidDuplicateAndDefinitionEditFailBeforeAnyMutation() throws {
        let packet = try prepare(), before = try Data(contentsOf: registry)
        XCTAssertThrowsError(try packet.apply(plan(packet, status: "duplicate"), prompt: packet.prompt(), marks: store))
        let block = packet.blocks[0]
        XCTAssertThrowsError(try packet.apply(plan(packet, edit: .init(block: block.id, text: "[S1]: /other\n")), prompt: packet.prompt(), marks: store))
        XCTAssertEqual(try Data(contentsOf: registry), before)
    }
    func testAlreadyMarkedUnchangedSourceIsNotPacketWork() throws {
        let fp = NoteFingerprint.read(forRecordingURL: media)
        try store.update([media.lastPathComponent: .init(status: .pending, source: "S1", markedAt: Date(), noteId: "note", text: fp.text, analysis: fp.analysis)])
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? SecretaryError, .nothingToDo) }
    }
    func testLargeDocumentSelectionPreservesBlocksAndLeavesUnknownEditsUnavailable() throws {
        let text = "# Test\n\n" + (0..<300).map { "## Section \($0)\n\n" + String(repeating: "old background ", count: 100) + "\n\n" }.joined()
        let blocks = SecretaryPacket.blocks(text)
        XCTAssertEqual(blocks.map(\.text).joined(), text)
        let selected = SecretaryPacket.select(blocks: blocks, sourceIDs: [], terms: [], limit: 1000)
        XCTAssertLessThanOrEqual(selected.reduce(0) { $0 + $1.text.utf8.count }, 1000)
        XCTAssertLessThan(selected.count, blocks.count)
    }
    func testRequiredSummaryBlocksBeatRepeatedBoilerplate() {
        let text = "# Документ\n\nВводная.\n\n" + (0..<80).map { "## Раздел \($0)\n\nНет существенных сведений; прежний фон.\n\n" }.joined()
            + "## Вопросы и наблюдения\n\nОткрытых вопросов нет.\n\n## Основания\n\nУчтён один источник.\n\n"
        let selected = SecretaryPacket.select(blocks: SecretaryPacket.blocks(text), sourceIDs: [], terms: ["сведений"], limit: 2000)
        XCTAssertTrue(selected.contains { $0.text.contains("Открытых вопросов нет.") })
        XCTAssertTrue(selected.contains { $0.text.contains("Учтён один источник.") })
        XCTAssertLessThan(selected.filter { $0.text.contains("прежний фон") }.count, 5)
    }
    func testShortSourceKeepsItsOwnTopicAgainstALargeOCRSource() {
        // Forty interface blocks share words with a large screenshot OCR; one section matches only
        // the short voice note, in another inflection ("балета", "Варвары" vs "балет", "Варвара").
        // Distinct words per block keep them "uncommon", as varied screenshot text is in practice.
        let uiWords = (0..<40).map { i in ["alpha", "bravo", "charlie", "delta", "echo"].map { "\(i)\($0)" }.joined(separator: " ") }
        let ui = uiWords.enumerated().map { "#### Экран \($0.offset)\n\n\($0.element).\n\n" }.joined()
        let text = "# Документ\n\nВводная.\n\n" + ui + "#### Недатированный поход на балет\n\nВарвары после балета было страшно.\n\n"
        let blocks = SecretaryPacket.blocks(text)
        let ocr = SecretaryPacket.terms(uiWords.joined(separator: " "))
        let voice = SecretaryPacket.terms("Это сказала Варвара, что больше на балет не пойдёт, испугалась")
        let pooled = SecretaryPacket.select(blocks: blocks, sourceIDs: [], terms: ocr.union(voice), limit: 600)
        XCTAssertFalse(pooled.contains { $0.text.contains("балета") }, "pooled ranking alone lets OCR crowd it out")
        let own = SecretaryPacket.select(blocks: blocks, sourceIDs: [], terms: ocr.union(voice), limit: 600, sourceTerms: [ocr, voice])
        XCTAssertTrue(own.contains { $0.text.contains("Варвары после балета") })
        XCTAssertTrue(own.contains { $0.text.contains("поход на балет") }, "the heading comes along as a neighbour")
        XCTAssertLessThanOrEqual(own.reduce(0) { $0 + $1.text.utf8.count }, 600)
    }
    func testFirstQuestionRemovesEmptyQueuePlaceholderWithoutChangingResolvedHistory() throws {
        let queueURL = root.appendingPathComponent("secretary/review_queue.md")
        try "## Открытые вопросы\n\nНет.\n\n## Разрешено\n\nQ7. Старая история.\n".write(to: queueURL, atomically: true, encoding: .utf8)
        let packet = try prepare()
        _ = try packet.apply(plan(packet, questions: ["Когда проверка?"]), prompt: packet.prompt(), marks: store)
        let queue = try String(contentsOf: queueURL, encoding: .utf8)
        XCTAssertTrue(queue.contains("Q8.")); XCTAssertTrue(queue.contains("Q7. Старая история."))
        XCTAssertFalse(SecretaryPacket.openQuestions(queue).contains("Нет."))
    }
    func testPacketExecutorHasNoToolsOrMCPAndRetainsSubscriptionAuthentication() {
        var request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "P", kind: .pass,
            wimmCLI: "/cli", budgetUSD: 0.5, model: "sonnet", timeout: 60)
        request.systemPrompt = "semantic policy"
        let args = ClaudeCodeExecutor(binary: URL(fileURLWithPath: "/claude")).arguments(for: request, mcpConfig: root.appendingPathComponent("mcp.json"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--max-turns")! + 1], "1")
        XCTAssertTrue(args.contains("--safe-mode")); XCTAssertFalse(args.contains("--bare"))
        XCTAssertFalse(args.contains("--allowedTools")); XCTAssertTrue(args.contains("--system-prompt-file"))
    }
    func testContextExpansionStopsAfterTwoRequestsAndKeepsAllPaidCosts() async throws {
        let body = "{\"summary\":\"Нужен контекст\",\"read_sections\":[\"b2\"]}"
        let executor = PacketFakeExecutor(body: body, cost: 0.03)
        let dispatcher = SecretaryDispatcher(executor: executor, wimmCLI: URL(fileURLWithPath: "/usr/bin/true"), budgetUSD: 0.10)
        let before = try Data(contentsOf: document)
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertTrue(execution.isError); XCTAssertEqual(execution.costUSD, 0.06)
        XCTAssertEqual(try Data(contentsOf: document), before); XCTAssertTrue(store.marks().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.workspace.runDirectory(task.id).appendingPathComponent("packet-2/input.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.workspace.runDirectory(task.id).appendingPathComponent("packet-3/input.json").path))
    }
    func testMalformedResultRetainsCostAndDoesNotTouchWorkspace() async throws {
        let dispatcher = SecretaryDispatcher(executor: PacketFakeExecutor(body: "not JSON", cost: 0.04), wimmCLI: URL(fileURLWithPath: "/usr/bin/true"))
        let before = try Data(contentsOf: registry)
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertTrue(execution.isError); XCTAssertEqual(execution.costUSD, 0.04)
        XCTAssertEqual(try Data(contentsOf: registry), before)
    }
    func testUnknownCostRefusesPaidContextExpansion() async throws {
        let body = "{\"summary\":\"Нужен контекст\",\"source_decisions\":[],\"edits\":[],\"questions\":[],\"needs_context\":[\"Маяк\"]}"
        let dispatcher = SecretaryDispatcher(executor: PacketFakeExecutor(body: body, cost: nil), wimmCLI: URL(fileURLWithPath: "/usr/bin/true"))
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertTrue(execution.isError); XCTAssertNil(execution.costUSD)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.workspace.runDirectory(task.id).appendingPathComponent("packet-2").path))
    }
    func testAudioPacketKeepsAllDistinctTranscriptsAndExactReadCoverage() throws {
        let audioURL = root.appendingPathComponent("recordings/voice.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let cloudWords = (1...2400).map { "облако\($0)" }.joined(separator: " ") + " CLOUDONLYFACT"
        let localWords = (1...2300).map { "локально\($0)" }.joined(separator: " ") + " LOCALREDUNDANTBODY"
        let realtimeWords = (1...1100).map { "поток\($0)" }.joined(separator: " ") + " REALTIMEREDUNDANTBODY"
        let refinedText = (1...1200).map { "сводка\($0)" }.joined(separator: " ") + String(repeating: "q", count: 20_000) + " REFINEDSUMMARY"
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audioURL)) {
            $0["recordingId"] = "voice"
            $0["duration"] = 2365.6
            $0["noteCard"] = ["refined_text": refinedText, "processed_at": "2026-10-20T21:10:00Z"]
            $0["transcription"] = [
                "transcript": localWords,
                "provider": "parakeet",
                "model": "ultra",
                "localTranscript": realtimeWords,
                "previousRuns": [[
                    "transcript": cloudWords,
                    "provider": "gemini",
                    "model": "gemini-2.5-flash",
                    "transcribedAt": "2026-10-20T21:08:00Z",
                    "replacedAt": "2026-10-24T22:57:00Z"
                ]]
            ]
            return true
        }
        try writeRegistry(sources: [["source_id": "S1", "path": "../recordings/voice.meta.json", "note_file": "voice.m4a", "status": "pending", "reason": "audio"]])
        let audioLib = RecallLibrary([RecallNote(id: "voice", date: Date(), kind: "audio",
            title: "Звонок", summary: nil, text: localWords, filePath: audioURL.path, duration: 2365.6, speech: "speech", updated: Date())])
        // Full evidence exceeds the normal solo limit: placed in blocked_sources in format 2.
        let blocked = try SecretaryPacket.prepare(task: task, library: audioLib, marks: store, sourceByteLimit: 64_000)
        let blockedList = blocked.payload["blocked_sources"] as? [[String: String]] ?? []
        XCTAssertEqual(blockedList.map { $0["source"] }, ["S1"])
        let packet = try SecretaryPacket.prepare(task: task, library: audioLib, marks: store, sourceByteLimit: 128_000)
        let initial = try packet.prompt()
        let cloudStamp = MCPRecallServer.iso("2026-10-20T21:08:00Z")
        let noteStamp = MCPRecallServer.iso(audioLib[0].date)
        XCTAssertTrue(initial.contains("earlier cloud transcript (gemini/gemini-2.5-flash, \(cloudStamp), 2401 words)"))
        XCTAssertTrue(initial.contains("primary transcript (parakeet/ultra, \(noteStamp), 2301 words) ---"))
        XCTAssertTrue(initial.contains("realtime transcript (\(noteStamp), 1101 words) ---"))
        XCTAssertTrue(initial.contains("CLOUDONLYFACT"))
        XCTAssertTrue(initial.contains("REFINEDSUMMARY"))
        XCTAssertTrue(initial.contains("LOCALREDUNDANTBODY"))
        XCTAssertTrue(packet.receipts[0].allAvailableTextSupplied)
        XCTAssertEqual(packet.receipts[0].localVariantSupplied, true)
        XCTAssertTrue(initial.contains("REALTIMEREDUNDANTBODY"))
        XCTAssertFalse(initial.contains("omitted in packet"))

        // A full-source request reuses the same complete snapshot.
        let expanded = try packet.prompt(extra: ["S1"])
        XCTAssertTrue(expanded.contains("LOCALREDUNDANTBODY"))
        XCTAssertTrue(expanded.contains("REALTIMEREDUNDANTBODY"))
    }
    func testAudioPacketPreservesSupplementaryTailWhenLowerTierHasMoreWords() throws {
        let audioURL = root.appendingPathComponent("recordings/tail.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let sharedPrefix = (1...60).map { "слово\($0)" }.joined(separator: " ")
        let droppedTail = (61...110).map { "хвост\($0)" }.joined(separator: " ") + " DROPPEDTAILFACT"
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audioURL)) {
            $0["recordingId"] = "tail"
            $0["duration"] = 180.0
            $0["transcription"] = [
                "transcript": sharedPrefix,
                "provider": "gemini",
                "model": "gemini-2.5-flash",
                "localTranscript": sharedPrefix + " " + droppedTail
            ]
            return true
        }
        try writeRegistry(sources: [["source_id": "S1", "path": "../recordings/tail.meta.json", "note_file": "tail.m4a", "status": "pending", "reason": "audio"]])
        let audioLib = RecallLibrary([RecallNote(id: "tail", date: Date(), kind: "audio",
            title: nil, summary: nil, text: sharedPrefix, filePath: audioURL.path, duration: 180.0, speech: "speech", updated: Date())])
        let input = try SecretaryPacket.prepare(task: task, library: audioLib, marks: store).prompt()
        let tailStamp = MCPRecallServer.iso(audioLib[0].date)
        XCTAssertTrue(input.contains("primary transcript (gemini/gemini-2.5-flash, \(tailStamp), 60 words)"))
        XCTAssertTrue(input.contains("realtime transcript (\(tailStamp), 111 words)"))
        XCTAssertFalse(input.contains("[supplementary diff"))
        XCTAssertTrue(input.contains(sharedPrefix))
        XCTAssertTrue(input.contains("DROPPEDTAILFACT"))
    }
    func testShortConflictingVariantAndReorderedPassagesRemainVerbatim() throws {
        let audio = root.appendingPathComponent("recordings/conflict.m4a")
        try Data().write(to: audio)
        let a = "Я не хочу продавать машину. Завтра я сначала позвоню в банк. Потом вечером я подпишу договор."
        let b = "Потом вечером я подпишу договор. Завтра я сначала позвоню в банк. Я хочу продавать машину."
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) {
            $0["transcription"] = ["transcript": a, "provider": "gemini", "model": "gemini-3-flash-preview",
                                  "previousRuns": [["transcript": b, "provider": "parakeet", "model": "ultra"]]]
            return true
        }
        let notes = RecallLibrary([RecallNote(id: "conflict", date: Date(), kind: "audio", title: nil,
            summary: nil, text: a, filePath: audio.path, duration: 60, speech: "speech", updated: Date())])
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        let supplied = (packet.payload["sources"] as! [[String: Any]])[0]["full_text"] as! String
        XCTAssertTrue(supplied.contains(a)); XCTAssertTrue(supplied.contains(b))
        XCTAssertFalse(supplied.contains("supplementary diff"))
        XCTAssertTrue(packet.receipts[0].allAvailableTextSupplied)
        XCTAssertFalse(packet.system.contains("highest-tier healthy"))
    }

    func testUnavailableFullSourceRequestsFailLocally() throws {
        let packet = try prepare()
        XCTAssertThrowsError(try packet.prompt(extra: ["full:S999"]))
        // Bare IDs search document mentions; they never admit additional raw source evidence.
        XCTAssertNoThrow(try packet.prompt(extra: ["S999"]))
        XCTAssertThrowsError(try packet.prompt(extra: ["full:invalid"]))
        // Ordinary search phrases beginning with S are not source IDs.
        XCTAssertNoThrow(try packet.prompt(extra: ["Settings"]))
        try String(repeating: "x", count: 260_001).write(to: media, atomically: true, encoding: .utf8)
        let large = try prepare(sourceLimit: 200_000)
        // Already admitted full evidence is reused, without another read or an old 256 KB cap.
        XCTAssertNoThrow(try large.prompt(extra: ["full:S1"]))
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testPartialReadCannotProduceAReviewMarkAndLegacyReceiptsHaveUnknownScope() async throws {
        try String(repeating: "long body ", count: 4000).write(to: media, atomically: true, encoding: .utf8)
        let notes = library
        let server = MCPRecallServer(marks: store, library: { notes })
        let read = server.readNote(library[0])
        let receipt = try XCTUnwrap(read.receipt)
        XCTAssertFalse(receipt.allAvailableTextSupplied)
        XCTAssertTrue(receipt.suppliedText?.contains { $0.state == "truncated" } == true)
        try receipt.append(to: SecretaryReadReceipt.logURL(runID: task.id, store: store))
        try SecretaryRegistryRevision.snapshot(try Data(contentsOf: registry), directory: task.workspace.runDirectory(task.id))
        let decision = SecretaryResult.SourceDecision(source: "S1", status: "applied", reason: "reviewed")
        let file = media
        let result = SecretaryResult(sourceDecisions: [decision])
        let report = await SecretaryBookkeeping.finish(task: task, result: result, store: store, recordings: { [file] })
        XCTAssertEqual(report.stored, 0)
        XCTAssertTrue(report.findings.contains { $0.contains("coverage") })
        XCTAssertTrue(store.marks().isEmpty)
        let legacy = SecretaryReadReceipt(file: receipt.file, sidecar: receipt.sidecar, noteID: receipt.noteID,
            sha256: receipt.sha256, text: receipt.text, analysis: receipt.analysis)
        let decoded = try JSONDecoder().decode(SecretaryReadReceipt.self, from: Self.canonicalJSONEncoder.encode(legacy))
        XCTAssertFalse(decoded.allAvailableTextSupplied)
        XCTAssertNil(decoded.localVariantSupplied)
        let oldRow: [String: Any] = ["source_id": "S1", "status": "pending", "local_variant_read": true]
        let legacyRow = try SecretaryRegistryRevision.revised(oldRow, decision: decision, receipt: decoded, task: task, known: ["S1"])
        XCTAssertNil(legacyRow["local_variant_read"])
        XCTAssertEqual(legacyRow["read_scope"] as? String, "version_only")
        let complete = try XCTUnwrap(server.readNote(library[0], full: true).receipt)
        let fullRow = try SecretaryRegistryRevision.revised(oldRow, decision: decision, receipt: complete, task: task, known: ["S1"])
        XCTAssertEqual(fullRow["local_variant_read"] as? Bool, false, "a field on disk is not proof a local ASR variant was supplied")
        XCTAssertEqual(fullRow["read_scope"] as? String, "all_available_text_recheck")
    }

    private func twoTaskSources() throws -> RecallLibrary {
        let second = root.appendingPathComponent("recordings/task-second.txt")
        try "Отдельная тема требует уточнения".write(to: second, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: second)) { $0["recordingId"] = "second"; return true }
        try writeRegistry(sources: [
            ["source_id": "S1", "path": "../recordings/note.meta.json", "note_file": "note.txt", "status": "pending"],
            ["source_id": "S2", "path": "../recordings/task-second.meta.json", "note_file": "task-second.txt", "status": "pending"]
        ])
        return RecallLibrary([library[0], RecallNote(id: "second", date: Date(), kind: "text", title: nil, summary: nil,
            text: "Отдельная тема требует уточнения", filePath: second.path, updated: Date())])
    }

    private func workTask(_ id: String, source: String, state: String = "ready", edits: [SecretaryPacket.Edit] = [],
                          needs: [String] = [], depends: [String] = [], reads: [String] = []) -> SecretaryPacket.WorkTask {
        .init(id: id, state: state, sources: [source], dependsOn: depends, readBlocks: reads,
              edits: edits, questions: [], needsContext: needs, reason: "Причина и следующий шаг")
    }

    func testNoteWithoutTextStaysOutOfThePacket() throws {
        let silent = root.appendingPathComponent("recordings/silent.m4a")
        try Data().write(to: silent)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: silent)) {
            $0["recordingId"] = "silent"; $0["transcription"] = ["speechStatus": "failed"]; return true
        }
        let notes = RecallLibrary([library[0], RecallNote(id: "silent", date: Date(), kind: "audio", title: nil, summary: nil,
                                                          text: "", filePath: silent.path, speech: "failed", updated: Date())])
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        XCTAssertEqual(packet.selected, ["S1"])
        XCTAssertEqual((packet.payload["no_text_sources"] as? [[String: String]])?.first?["file"], "silent.m4a")
        XCTAssertFalse(try packet.prompt().contains("silent.m4a"), "host bookkeeping, not model input")
        XCTAssertThrowsError(try SecretaryPacket.prepare(task: task, library: RecallLibrary([notes[1]]), marks: store)) {
            XCTAssertTrue($0.localizedDescription.contains("without text"))
        }
    }

    /// 2026-11-14: 172 of the 200 newest changes had no transcript, so a 1000 KB
    /// budget yielded 15 sources while 1016 waited. The byte budget, not a
    /// candidate page, ends selection.
    func testNotesWithoutTextDoNotHideOlderSourcesFromTheBudget() throws {
        var notes = [library[0]]
        for i in 0..<210 {
            let silent = root.appendingPathComponent("recordings/silent-\(i).m4a")
            try Data().write(to: silent)
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: silent)) {
                $0["recordingId"] = "silent-\(i)"; $0["transcription"] = ["speechStatus": "failed"]; return true
            }
            notes.append(RecallNote(id: "silent-\(i)", date: Date(), kind: "audio", title: nil, summary: nil, text: "",
                                    filePath: silent.path, speech: "failed", updated: Date().addingTimeInterval(3600 + Double(i))))
        }
        let packet = try SecretaryPacket.prepare(task: task, library: RecallLibrary(notes), marks: store)
        XCTAssertEqual(packet.selected, ["S1"])
        XCTAssertEqual((packet.payload["no_text_sources"] as? [[String: String]])?.count, 210)
    }

    func testRemovedReferenceRequeuesItsNote() throws {
        let fresh = Date().addingTimeInterval(3600)
        try store.update(["note.txt": AgentMarkStore.Mark(status: .applied, source: "S1", markedAt: Date(), noteId: "note", text: "t", analysis: "a")])
        try store.setPass(.init(asOf: fresh, cursor: nil, comment: "ahead of the note", setAt: Date()))
        let requeued = SecretaryBookkeeping.requeue(["S1", "U7", "S99"], workspace: task.workspace, store: store)
        XCTAssertEqual(requeued, ["note.txt"], "only registered S… sources map to notes")
        XCTAssertNil(store.mark(forFile: "note.txt"))
        XCTAssertLessThan(try XCTUnwrap(store.pass()).asOf, Date(), "the boundary moves back so the note is a candidate again")
        XCTAssertEqual(try SecretaryPacket.prepare(task: task, library: library, marks: store).selected, ["S1"])
    }

    func testBlockReplacementKeepsTheParagraphSeparator() throws {
        let packet = try prepare()
        let block = try XCTUnwrap(packet.blocks.first { $0.text.contains("Сводка") })
        XCTAssertTrue(block.text.hasSuffix("\n\n"))
        let edits = try packet.materializedEdits([.init(block: block.id, text: "Сводка: проект Маяк, обновлено [S1].")], allowed: [block.id])
        XCTAssertEqual(edits.first?.text, "Сводка: проект Маяк, обновлено [S1].\n\n")
        let removed = try packet.materializedEdits([.init(block: block.id, text: "")], allowed: [block.id])
        XCTAssertEqual(removed.first?.text, "", "an emptied block stays empty")
    }

    func testDecisionsAboutListedButUnadmittedSourcesAreDroppedNotFatal() throws {
        let notes = try twoTaskSources()
        let hold: [String: Any] = ["active": true, "authority": "user", "scope": "source",
            "resume": "explicit_user_release", "reason": "Temporarily ignore"]
        try writeRegistry(sources: [
            ["source_id": "S1", "path": "../recordings/note.meta.json", "note_file": "note.txt", "status": "noise", "user_exclusion": hold],
            ["source_id": "S2", "path": "../recordings/task-second.meta.json", "note_file": "task-second.txt", "status": "pending"]
        ])
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        XCTAssertEqual(packet.selected, ["S2"])
        var output = SecretaryPacket.Plan(summary: "Проверено", sourceDecisions: ["S1", "S2"].map {
            .init(source: $0, status: "pending", reason: "Проверено")
        }, edits: [], questions: [], needsContext: [])
        output.tasks = [workTask("held", source: "S1"), workTask("real", source: "S2")]
        let resolution = try packet.resolveTasks(output, prompt: packet.prompt(), marks: store)
        XCTAssertEqual(resolution.ignoredSources, ["S1"])
        XCTAssertEqual(resolution.readyCount, 1)
        XCTAssertEqual(resolution.plan.sourceDecisions.map(\.source), ["S2"])

        var flat = output; flat.tasks = nil
        XCTAssertNoThrow(try packet.apply(flat, prompt: packet.prompt(), marks: store, validateOnly: true))

        var asks = output
        asks.tasks = [.init(id: "held", state: "ready", sources: ["S1"], dependsOn: [], readBlocks: [], edits: [],
                            questions: ["Что на снимке?"], needsContext: [], reason: "Вопрос"), workTask("real", source: "S2")]
        XCTAssertThrowsError(try packet.resolveTasks(asks, prompt: packet.prompt(), marks: store)) {
            XCTAssertTrue($0.localizedDescription.contains("not supplied"))
        }
        var unknown = output
        unknown.tasks = [workTask("ghost", source: "S9"), workTask("real", source: "S2")]
        unknown = .init(summary: "x", sourceDecisions: unknown.sourceDecisions + [.init(source: "S9", status: "pending", reason: "x")],
                        edits: [], questions: [], needsContext: [])
        unknown.tasks = [workTask("ghost", source: "S9"), workTask("real", source: "S2")]
        XCTAssertThrowsError(try packet.resolveTasks(unknown, prompt: packet.prompt(), marks: store), "Unlisted sources still fail")
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testDroppedReferencesAreLoggedUnlessTheyMove() throws {
        try "# Документ\n\nСводка: проект Маяк [S1].\n\n## Вопросы\n\n1. Маяк: когда запуск? [S1]\n2. Кто такой Давид? [U7]\n\n## Маяк\n\nСтарый факт: запуск 12 октября [S1].\n\n[S1]: ../recordings/note.meta.json\n"
            .write(to: document, atomically: true, encoding: .utf8)
        let packet = try prepare()
        let questions = try XCTUnwrap(packet.blocks.first { $0.text.contains("Кто такой Давид") })
        let topic = try XCTUnwrap(packet.blocks.first { $0.text.contains("Старый факт") })
        func resolve(_ edits: [SecretaryPacket.Edit]) throws -> SecretaryPacket.TaskResolution {
            var output = plan(packet); output.tasks = [workTask("t", source: "S1", edits: edits)]
            return try packet.resolveTasks(output, prompt: packet.prompt(), marks: store)
        }
        // A whole-block rewrite that keeps only the answered question loses U7: allowed, but logged.
        let dropped = try resolve([.init(block: questions.id, text: "1. Маяк: запуск 30 октября [S1].\n\n")])
        XCTAssertEqual(dropped.readyCount, 1)
        XCTAssertEqual(dropped.reports[0].droppedReferences, ["U7"])
        // Moving the reference into another edited block of the same task is not a drop.
        let moved = try resolve([.init(block: questions.id, text: "1. Маяк: запуск 30 октября [S1].\n\n"),
                                 .init(block: topic.id, text: "Старый факт: запуск 12 октября [S1]. Давид — вопрос открыт [U7].\n\n")])
        XCTAssertEqual(moved.readyCount, 1)
        XCTAssertNil(moved.reports[0].droppedReferences)
        // Narrow operations keep the rest of the block, so they pass.
        let narrow = try resolve([.init(block: questions.id, text: "30 октября", operation: "replace_text", match: "когда запуск?")])
        XCTAssertEqual(narrow.readyCount, 1)
    }

    func testTaskValidationIsLocalAndResolutionDoesNotWrite() throws {
        let notes = try twoTaskSources(), before = try Data(contentsOf: document)
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        var output = SecretaryPacket.Plan(summary: "Проверено", sourceDecisions: packet.selected.map {
            .init(source: $0, status: $0 == "S1" ? "invalid" : "pending", reason: "Проверено")
        }, edits: [], questions: [], needsContext: [])
        output.tasks = [workTask("bad", source: "S1"), workTask("good", source: "S2")]
        let resolution = try packet.resolveTasks(output, prompt: packet.prompt(), marks: store)
        XCTAssertEqual(resolution.readyCount, 1)
        XCTAssertEqual(resolution.plan.sourceDecisions.map(\.source), ["S2"])
        XCTAssertEqual(resolution.reports.first?.state, "deferred")
        XCTAssertThrowsError(try resolution.packet.apply(resolution.plan, prompt: packet.prompt(), marks: store,
            validationRows: [:], validationBlocks: []), "Cached preflight data must never authorize writes")
        XCTAssertEqual(try Data(contentsOf: document), before)
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testTaskConflictsCyclesAndDeferredDependenciesCannotApply() throws {
        let notes = try twoTaskSources()
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        let block = try XCTUnwrap(packet.blocks.first { $0.text.contains("Старый факт") })
        let edit = SecretaryPacket.Edit(block: block.id, text: "Новая версия [S1].")
        let cases: [[SecretaryPacket.WorkTask]] = [
            [workTask("one", source: "S1", edits: [edit]), workTask("two", source: "S2", edits: [edit])],
            [workTask("one", source: "S1", depends: ["two"]), workTask("two", source: "S2", depends: ["one"])],
            [workTask("one", source: "S1", depends: ["two"]), workTask("two", source: "S2", state: "deferred", needs: ["Маяк"])],
            [workTask("one", source: "S1", edits: [.init(block: block.id, text: "Новое утверждение [S2].")]), workTask("two", source: "S2", state: "deferred", needs: ["Маяк"])],
            [workTask("one", source: "S1", edits: [edit]), workTask("two", source: "S2", reads: [block.id])]
        ]
        for tasks in cases {
            var output = plan(packet); output.tasks = tasks
            let resolution = try packet.resolveTasks(output, prompt: packet.prompt(), marks: store)
            XCTAssertEqual(resolution.readyCount, 0)
            XCTAssertTrue(resolution.plan.sourceDecisions.isEmpty)
        }
        // A source in no task is simply not acknowledged; naming one twice is invalid.
        var partial = plan(packet); partial.tasks = [workTask("one", source: "S1")]
        XCTAssertEqual(try packet.resolveTasks(partial, prompt: packet.prompt(), marks: store).plan.sourceDecisions.map(\.source), ["S1"])
        var invalid = plan(packet); invalid.tasks = [workTask("one", source: "S1"), workTask("two", source: "S1")]
        XCTAssertThrowsError(try packet.resolveTasks(invalid, prompt: packet.prompt(), marks: store))
    }

    func testBlockObjectsStateSectionOnlyWhenItChanges() {
        let blocks = SecretaryPacket.blocks("## A\n\nx\n\ny\n\n## B\n\nz\n\n")
        let all = SecretaryPacket.objects(blocks)
        XCTAssertEqual(all.map { $0["section"] }, [nil, nil, nil, nil, nil], "heading blocks introduce their own section")
        let withoutHeadings = SecretaryPacket.objects(blocks.filter { !$0.text.hasPrefix("##") })
        XCTAssertEqual(withoutHeadings.map { $0["section"] }, ["## A", nil, "## B"])
        XCTAssertEqual(withoutHeadings.map { $0["id"] }, blocks.filter { !$0.text.hasPrefix("##") }.map(\.id))
    }

    func testExactContextReportDistinguishesAbsentMentionFromBudgetOmission() throws {
        let blocks = SecretaryPacket.blocks("## Бот\n\nРассылка запущена.\n\n")
        let selection = SecretaryPacket.contextSelection(blocks: blocks, requests: ["Fleurop; Рассылка"], existing: [], limit: 0)
        let clauses = try XCTUnwrap(selection.reports.first?.clauses)
        XCTAssertEqual(clauses[0].status, "no_exact_document_mention")
        XCTAssertEqual(clauses[1].status, "exact_document_mention")
        XCTAssertFalse(clauses[1].exactMatches.isEmpty)
        XCTAssertTrue(clauses[1].suppliedExactMatches.isEmpty)
    }

    func testAddressedReadsArePaginatedAndNeverTruncateSourceEvidence() throws {
        let notes = try twoTaskSources()
        let secondFile = root.appendingPathComponent("recordings/task-second.txt")
        let fp = NoteFingerprint.read(forRecordingURL: secondFile)
        try store.update([secondFile.lastPathComponent: .init(status: .pending, source: "S2", markedAt: Date(), noteId: "second", text: fp.text, analysis: fp.analysis)])
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        let requests = [SecretaryPacket.ReadRequest(id: "read", operation: "source", query: "S2", purpose: "Check evidence")]
        let turn = try packet.addressedRead(requests, validationPrompt: packet.prompt(), library: notes, marks: store, sourceLimit: 1, documentLimit: 1)
        XCTAssertEqual(turn.packet.selected, ["S1"])
        XCTAssertTrue(turn.reply.contains("source_budget_exceeded"))
        XCTAssertFalse(turn.reply.contains("Отдельная тема требует уточнения"))
        let oversized = "# Документ\n\n## Большой раздел\n\n" + String(repeating: "Большой абзац ", count: 2000)
        try oversized.write(to: document, atomically: true, encoding: .utf8)
        let fresh = try SecretaryPacket.prepare(task: task, library: notes, marks: store, documentByteLimit: 1)
        let section = try fresh.addressedRead([.init(id: "section", operation: "section", query: "Большой раздел", purpose: "Read complete paragraph")],
            validationPrompt: fresh.prompt(), library: notes, marks: store, sourceLimit: 64_000, documentLimit: 200)
        XCTAssertTrue(section.reply.contains("next_offset"))
        XCTAssertFalse(section.reply.contains(String(repeating: "Большой абзац ", count: 5)))
        XCTAssertLessThanOrEqual(section.documentBytes, 200)
    }

    func testSessionArgumentsKeepToolAndSandboxRestrictions() throws {
        var request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "delta", kind: .pass,
            wimmCLI: "/cli", budgetUSD: 1, model: nil, timeout: 30)
        request.systemPrompt = "policy"; request.packetSession = true; request.resumeSessionID = PacketSessionExecutor.sessionID
        let codex = CodexExecutor(binary: URL(fileURLWithPath: "/codex")).arguments(for: request, lastMessage: root.appendingPathComponent("last"))
        XCTAssertTrue(codex.contains("resume")); XCTAssertFalse(codex.contains("--ephemeral"))
        XCTAssertTrue(codex.contains("read-only")); XCTAssertTrue(codex.contains("features.shell_tool=false"))
        XCTAssertTrue(codex.contains("--ignore-user-config")); XCTAssertEqual(codex.last, "-")
        let claude = ClaudeCodeExecutor(binary: URL(fileURLWithPath: "/claude")).arguments(for: request, mcpConfig: root.appendingPathComponent("mcp.json"))
        XCTAssertTrue(claude.contains("--resume")); XCTAssertTrue(claude.contains("--strict-mcp-config"))
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        request.resumeSessionID = "--last"
        XCTAssertThrowsError(try request.validatePacketResume())
    }

    func testRunQualityIsProjectedWithoutCurrentMetricsLeakingIntoOtherVariants() throws {
        let audio = root.appendingPathComponent("recordings/quality.m4a")
        try Data().write(to: audio)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) {
            $0["transcription"] = ["transcript": "Местная запись", "provider": "parakeet", "model": "ultra",
                "confidence": 0.93, "quality": ["status": "ok", "p10Confidence": 0.42],
                "localTranscript": "Живой текст",
                "previousRuns": [["transcript": "Облачная версия", "provider": "gemini", "model": "gemini-3-flash-preview",
                                  "quality": ["status": "suspect", "issues": ["loop:phrase"]]]]]
            return true
        }
        let note = RecallNote(id: "quality", date: Date(), kind: "audio", title: nil, summary: nil, text: "Местная запись", filePath: audio.path)
        let server = MCPRecallServer(marks: store, library: { RecallLibrary([note]) })
        let read = server.readNote(note, full: true)
        let lines = read.text.components(separatedBy: "\n")
        let local = try XCTUnwrap(lines.first { $0.hasPrefix("asr_quality[transcript (") })
        let start = try XCTUnwrap(local.range(of: "]: "))
        let metrics = try JSONSerialization.jsonObject(with: Data(local[start.upperBound...].utf8)) as! [String: Any]
        XCTAssertEqual((metrics["confidence"] as? NSNumber)?.doubleValue ?? 0, 0.93, accuracy: 0.001)
        XCTAssertEqual((metrics["p10Confidence"] as? NSNumber)?.doubleValue ?? 0, 0.42, accuracy: 0.001)
        XCTAssertTrue(local.contains("unknown"), "legacy ok does not record which checks ran")
        let cloud = try XCTUnwrap(lines.first { $0.hasPrefix("asr_quality[earlier cloud") })
        XCTAssertTrue(cloud.contains("loop:phrase")); XCTAssertFalse(cloud.contains("0.93"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("asr_quality[realtime") })
        XCTAssertTrue(try XCTUnwrap(read.receipt).allAvailableTextSupplied)
        let compact = server.readNote(note, full: true, format: .secretaryPacket)
        XCTAssertEqual(lines.filter { $0.hasPrefix("asr_quality[") },
                       compact.text.components(separatedBy: "\n").filter { $0.hasPrefix("asr_quality[") })
        XCTAssertEqual(try Self.canonicalJSONEncoder.encode(read.receipt?.suppliedText), try Self.canonicalJSONEncoder.encode(compact.receipt?.suppliedText))
        // A legacy recorder string is known realtime evidence, not an unknown file run.
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) {
            $0["transcription"] = "Старый живой текст"; return true
        }
        let legacyRead = server.readNote(note, full: true)
        XCTAssertEqual(try XCTUnwrap(legacyRead.receipt).localVariantSupplied, true)
        XCTAssertTrue(legacyRead.text.contains("Старый живой текст"))
        // Canonically equivalent Unicode is not byte-identical source evidence.
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) {
            $0["transcription"] = ["transcript": "é", "localTranscript": "e\u{301}", "provider": "gemini"]
            return true
        }
        let unicodeRead = server.readNote(note, full: true)
        XCTAssertEqual(unicodeRead.receipt?.suppliedText?.filter { $0.state == "full" }.count, 2)
        XCTAssertFalse(unicodeRead.receipt?.suppliedText?.contains { $0.state == "duplicate" } ?? true)
    }

}

private struct PacketFakeExecutor: SecretaryExecutor {
    var name = "claude-code"
    let body: String
    let cost: Double?
    func run(_ request: SecretaryExecutionRequest, onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        SecretaryExecution(exitStatus: 0, finalText: body, costUSD: cost, tokensIn: 100, tokensOut: 10, turns: 1)
    }
}

private actor PacketRepairExecutor: SecretaryExecutor {
    nonisolated let name = "claude-code"
    let bodies: [String]
    let cost: Double?
    let mutateOnRepair: URL?
    var requests: [SecretaryExecutionRequest] = []
    init(bodies: [String], cost: Double? = 0.02, mutateOnRepair: URL? = nil) {
        self.bodies = bodies; self.cost = cost; self.mutateOnRepair = mutateOnRepair
    }
    func run(_ request: SecretaryExecutionRequest, onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        requests.append(request)
        if requests.count == 2, let mutateOnRepair {
            try "Concurrent edit".write(to: mutateOnRepair, atomically: true, encoding: .utf8)
        }
        return SecretaryExecution(exitStatus: 0, finalText: bodies[min(requests.count - 1, bodies.count - 1)], costUSD: cost,
                                  tokensIn: 100, tokensOut: 10, turns: 1)
    }
}

private actor PacketSessionExecutor: SecretaryExecutor {
    nonisolated let name = "codex"
    nonisolated let supportsPacketSessions = true
    nonisolated static let sessionID = "00000000-0000-4000-8000-000000000001"
    let bodies: [String]
    let changeSession: Bool
    var requests: [SecretaryExecutionRequest] = []
    init(bodies: [String], changeSession: Bool = false) { self.bodies = bodies; self.changeSession = changeSession }
    func run(_ request: SecretaryExecutionRequest, onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        requests.append(request)
        return SecretaryExecution(exitStatus: 0, finalText: bodies[min(requests.count - 1, bodies.count - 1)],
            tokensIn: 100, tokensOut: 10, turns: 1,
            sessionID: changeSession && requests.count > 1 ? "00000000-0000-4000-8000-000000000002" : Self.sessionID)
    }
}
