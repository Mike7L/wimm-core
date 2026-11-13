import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

/// Response format 2 (proposal 2026-10-31): edits + done_no_additions, outcomes inferred by Wimm.
final class SecretaryPacketEditsTests: XCTestCase {
    private var root: URL!
    private var store: AgentMarkStore!
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registry: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }
    private var task: SecretaryTask {
        SecretaryTask(id: "edits-test", kind: .pass, workspace: SecretaryWorkspace(document: document)!, threads: [],
                      wimmCLI: "/usr/bin/true", createdAt: Date(), packetMode: true)
    }
    private var files: [URL] = []
    private var library: RecallLibrary {
        RecallLibrary(files.enumerated().map { i, file in
            RecallNote(id: "n\(i)", date: Date(), kind: "text", title: nil, summary: nil, text: "cache", filePath: file.path, updated: Date())
        })
    }
    private let text = """
    # Документ

    Сводка [S1].

    ## Работа

    Работа идёт.

    ### Маяк

    Старый факт: запуск 12 октября [S1].

    ### Другое

    Прочее.

    ## Семья

    ### Маяк

    Семейный маяк.

    [S1]: ../recordings/n0.meta.json

    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("packet-edits-\(UUID().uuidString)")
        for name in ["recordings", "docs", "secretary/protocol", "secretary/runs/edits-test"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        store = AgentMarkStore(directory: root.appendingPathComponent("state"))
        try text.write(to: document, atomically: true, encoding: .utf8)
        try "Старый протокол.".write(to: root.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "Пиши только сказанное.".write(to: root.appendingPathComponent(SecretaryPacket.editsPolicyPath), atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\nНет.\n".write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        try makeSources(2)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeSources(_ count: Int) throws {
        files = (0..<count).map { root.appendingPathComponent("recordings/n\($0).txt") }
        var rows: [[String: Any]] = []
        for (i, file) in files.enumerated() {
            try "Заметка \(i): Маяк, экспорт Markdown пока только план.".write(to: file, atomically: true, encoding: .utf8)
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { $0["recordingId"] = "n\(i)"; return true }
            rows.append(["source_id": "S\(i + 1)", "path": "../recordings/n\(i).meta.json", "note_file": "n\(i).txt", "status": "pending", "reason": "unread"])
        }
        try JSONSerialization.data(withJSONObject: ["sources": rows, "source_count": rows.count, "counts": ["pending": rows.count], "batches": []]).write(to: registry)
    }
    private func prepare() throws -> SecretaryPacket { try SecretaryPacket.prepare(task: task, library: library, marks: store) }
    private func reply(_ object: [String: Any]) throws -> SecretaryPacket.EditsReply {
        try SecretaryPacket.decodeEdits(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    private func outcomes(_ report: SecretaryPacket.EditsReport) -> [String: String] {
        Dictionary(uniqueKeysWithValues: report.sources.map { ($0.id, $0.outcome) })
    }
    private func statuses(_ plan: SecretaryPacket.Plan) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.sourceDecisions.map { ($0.source, $0.status) })
    }
    private func block(_ packet: SecretaryPacket, _ needle: String) throws -> String {
        try XCTUnwrap(packet.blocks.first { $0.text.contains(needle) }).id
    }

    private func section(_ packet: SecretaryPacket, _ line: String, under parent: String? = nil) throws -> String {
        var inParent = parent == nil
        for block in packet.blocks {
            guard let h = SecretaryPacket.heading(block.text) else { continue }
            if let parent, h.line == parent { inParent = true; continue }
            if inParent, h.line == line { return block.id }
        }
        throw XCTSkip("no section \(line)")
    }
    private func edit(_ op: String, block: String? = nil, section: String? = nil, match: String? = nil,
                      text: String, sources: [String]) -> [String: Any] {
        var e: [String: Any] = ["operation": op, "text": text, "sources": sources]
        if let block { e["block"] = block }; if let section { e["section"] = section }; if let match { e["match"] = match }
        return e
    }

    func testPolicyFileSelectsFormatTwoAndTheInputCarriesIt() throws {
        let packet = try prepare()
        XCTAssertEqual(packet.responseFormat, 2)
        XCTAssertTrue(packet.system.hasPrefix(SecretaryPacket.editsContract))
        XCTAssertTrue(packet.system.contains("Пиши только сказанное."))
        let input = try JSONSerialization.jsonObject(with: Data(packet.prompt().utf8)) as! [String: Any]
        XCTAssertEqual(input["response_format"] as? Int, 2)
        XCTAssertNil(input["deferred_work"])
        let outline = try XCTUnwrap(input["outline"] as? [[String: String]], "format 2 gets the whole outline by block id")
        XCTAssertEqual(outline.count, 6)
        XCTAssertEqual(outline[2]["title"], "### Маяк"); XCTAssertNotNil(outline[2]["id"])
        try FileManager.default.removeItem(at: root.appendingPathComponent(SecretaryPacket.editsPolicyPath))
        let fallback = try prepare()
        XCTAssertEqual(fallback.responseFormat, 2)
        XCTAssertEqual(fallback.payload["response_format"] as? Int, 2)
        XCTAssertTrue(fallback.system.contains("Старый протокол."))
        XCTAssertTrue(fallback.system.hasPrefix(SecretaryPacket.editsContract))
    }

    func testFormatTwoRefusesOtherReplyShapes() {
        for body in [#"{"summary":"x","source_decisions":[],"tasks":[]}"#, #"{"edits":[],"nothing_to_add":["S1"]}"#] {
            XCTAssertThrowsError(try SecretaryPacket.decodeEdits(body)) { XCTAssertTrue($0.localizedDescription.contains("response format 2")) }
        }
        XCTAssertNoThrow(try SecretaryPacket.decodeEdits("```json\n{\"edits\":[],\"done_no_additions\":[{\"source\":\"S1\",\"reason\":\"повтор\"}]}\n```"))
        let wrapped = try? SecretaryPacket.decodeEdits(#"{"edits":[],"questions":["plain",{"q":"wrapped"},{"question":"long form"}]}"#)
        XCTAssertEqual(wrapped?.questions, ["plain", "wrapped", "long form"])
        XCTAssertThrowsError(try SecretaryPacket.decodeEdits(#"{"edits":[],"questions":[{"x":1}]}"#))
    }

    func testInsertUnderSuppliedSectionByIdAndExplicitOutcomes() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let lighthouse = try section(packet, "### Маяк", under: "## Работа")
        let resolution = try packet.resolveEdits(reply(["summary": "Маяк", "edits": [
            edit("insert_under_heading", section: lighthouse, text: "Экспорт Markdown — только план [S2].", sources: ["S2"]),
            edit("insert_under_heading", section: lighthouse, text: "Второй абзац [S2].\n", sources: ["S2"])],
            "done_no_additions": [["source": "S1", "reason": "повтор старого факта"]]]), prompt: prompt, marks: store)
        XCTAssertNil(resolution.report.rejection)
        XCTAssertEqual(outcomes(resolution.report), ["S1": "reviewed", "S2": "used"])
        XCTAssertEqual(statuses(resolution.plan), ["S1": "applied", "S2": "applied"], "S1 is already cited in the document")
        XCTAssertTrue(resolution.plan.sourceDecisions.first { $0.source == "S1" }!.reason.contains("повтор старого факта"))
        _ = try resolution.packet.apply(resolution.plan, prompt: prompt, marks: store)
        let written = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(written.contains("Старый факт: запуск 12 октября [S1].\n\nЭкспорт Markdown — только план [S2].\n\nВторой абзац [S2].\n\n### Другое"), written)
        XCTAssertTrue(written.hasSuffix("[S1]: ../recordings/n0.meta.json\n"), "definitions untouched")
    }

    func testRepeatedPlainInsertionsKeepParagraphBoundariesAndReplyOrder() throws {
        for operation in ["insert_before", "insert_after"] {
            let packet = try prepare(), prompt = try packet.prompt()
            let anchor = try block(packet, "Старый факт")
            let response = try reply(["edits": [
                edit(operation, block: anchor, text: "Первый абзац [S2].", sources: ["S2"]),
                edit(operation, block: anchor, text: "Второй абзац [S2].", sources: ["S2"])]] )
            let resolved = try packet.resolveEdits(response, prompt: prompt, marks: store)
            XCTAssertTrue(resolved.report.accepted, resolved.report.rejection ?? "")
            let edits = try resolved.packet.materializedEdits(resolved.plan.edits, allowed: [anchor])
            let expected = "Первый абзац [S2].\n\nВторой абзац [S2].\n\n"
            XCTAssertTrue(edits[0].text.contains(expected), edits[0].text)
            XCTAssertTrue(edits[0].text.contains("Старый факт: запуск 12 октября [S1]."))
        }
    }

    func testSectionMustBeSuppliedInFullAndCanBeReadOnce() throws {
        let packet = try prepare()
        var input = try JSONSerialization.jsonObject(with: Data(packet.prompt().utf8)) as! [String: Any]
        let family = try section(packet, "### Маяк", under: "## Семья")
        let familyText = try block(packet, "Семейный маяк")
        input["document_blocks"] = (input["document_blocks"] as! [[String: String]]).filter { $0["id"] != familyText }
        let narrow = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let body = try reply(["edits": [edit("insert_under_heading", section: family, text: "Эпизод [S2].", sources: ["S2"])]])
        let refused = try packet.resolveEdits(body, prompt: narrow, marks: store)
        XCTAssertTrue(refused.report.rejection?.contains("not supplied in full") == true)
        let widened = try packet.prompt(sections: [family], validationPrompt: narrow)
        XCTAssertTrue(widened.contains("Семейный маяк"))
        XCTAssertNil(try packet.resolveEdits(body, prompt: widened, marks: store).report.rejection)
        let again = try packet.resolveEdits(reply(["read_sections": [family]]), prompt: widened, marks: store)
        XCTAssertTrue(again.report.rejection?.contains("second read request") == true)
        XCTAssertThrowsError(try packet.prompt(sections: [familyText], validationPrompt: narrow), "only headings are sections")
    }

    func testInvalidEditDropsOnlyItsSourceGroup() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let fact = try block(packet, "Старый факт"), summary = try block(packet, "Сводка")
        let resolution = try packet.resolveEdits(reply(["edits": [
            edit("insert_after", block: summary, text: "Уточнение к запуску [S1].\n\n", sources: ["S1"]),
            edit("insert_after", block: summary, text: "Сводка дополнена [S2].\n\n", sources: ["S2"]),
            edit("replace_block", block: fact, text: "Всё заново [S2].", sources: ["S2"])],
            "done_no_additions": [["source": "S2", "reason": "x"]]]), prompt: prompt, marks: store)
        XCTAssertTrue(resolution.report.accepted, resolution.report.rejection ?? "")
        XCTAssertEqual(outcomes(resolution.report), ["S1": "used", "S2": "rejected"], "S2's list entry does not rescue it")
        XCTAssertEqual(resolution.report.rejectedEdits?.map(\.index), [1, 2], "the good S2 edit goes with the bad one")
        XCTAssertTrue(resolution.report.rejectedEdits?[0].reason.contains("shares S2") == true)
        XCTAssertTrue(resolution.report.rejectedEdits?[1].reason.contains("tidy pass") == true)
        XCTAssertTrue(resolution.report.sources.first { $0.id == "S2" }?.reason?.contains("Edit") == true)
        XCTAssertEqual(statuses(resolution.plan), ["S1": "applied"])
        _ = try resolution.packet.apply(resolution.plan, prompt: prompt, marks: store)
        let written = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(written.contains("Уточнение к запуску [S1]."))
        XCTAssertFalse(written.contains("Сводка дополнена"))
        XCTAssertFalse(written.contains("Всё заново"))
    }

    func testSourceGroupsJoinTransitivelyAndAnEmptyRemainderRejectsTheReply() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let fact = try block(packet, "Старый факт"), summary = try block(packet, "Сводка")
        let resolution = try packet.resolveEdits(reply(["edits": [
            edit("insert_after", block: summary, text: "Про первое [S1].\n\n", sources: ["S1"]),
            edit("insert_after", block: summary, text: "Связь [S1] и [S2].\n\n", sources: ["S1", "S2"]),
            edit("replace_block", block: fact, text: "Всё заново [S2].", sources: ["S2"])],
            "done_no_additions": [["source": "S1", "reason": "x"]]]), prompt: prompt, marks: store)
        XCTAssertFalse(resolution.report.accepted)
        XCTAssertTrue(resolution.report.rejection?.contains("tidy pass") == true, resolution.report.rejection ?? "accepted")
        XCTAssertEqual(Set(resolution.report.sources.map(\.outcome)), ["rejected"])
        XCTAssertNil(resolution.report.rejectedEdits)
        XCTAssertTrue(resolution.plan.sourceDecisions.isEmpty && resolution.plan.edits.isEmpty)
    }

    /// Every edit shares S2 here, so nothing survives and the reply is refused as before.
    func testOneInvalidEditRejectsTheWholeJob() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let fact = try block(packet, "Старый факт"), summary = try block(packet, "Сводка")
        let good = edit("insert_after", block: summary, text: "Сводка дополнена [S2].\n\n", sources: ["S2"])
        let bad: [[String: Any]] = [
            edit("replace_block", block: fact, text: "Всё заново [S2].", sources: ["S2"]),
            edit("replace_text", block: fact, match: "запуск 12 октября [S1]", text: "запуск 13 октября [S2]", sources: ["S2"]),
            edit("replace_text", block: fact, match: "Старый факт: " + String(repeating: "x", count: 0) + "запуск 12 октября", text: "y", sources: ["S2"]),
            edit("insert_after", block: summary, text: "Ссылка [S99].\n\n", sources: ["S2"]),
            edit("insert_after", block: summary, text: "Без имени [S1].\n\n", sources: ["S2"]),
            edit("insert_after", block: summary, text: "Без ссылки.\n\n", sources: ["S2"])]
        let expected = ["tidy pass", "drops references S1", "names S2 without citing", "S99", "cites S1 without naming", "names S2 without citing"]
        for (op, reason) in zip(bad, expected) {
            let resolution = try packet.resolveEdits(reply(["edits": [good, op], "done_no_additions": [["source": "S1", "reason": "x"]]]), prompt: prompt, marks: store)
            XCTAssertTrue(resolution.report.rejection?.contains(reason) == true, "\(reason): \(resolution.report.rejection ?? "accepted")")
            XCTAssertEqual(Set(resolution.report.sources.map(\.outcome)), ["rejected"])
            XCTAssertTrue(resolution.plan.sourceDecisions.isEmpty && resolution.plan.edits.isEmpty, "nothing of the job survives")
        }
    }

    func testEditionLineTakesAnEditWithoutSources() throws {
        try text.replacingOccurrences(of: "# Документ\n\n", with: "# Документ\n\n**Редакция: 3 ноября 2026.** Добавлено [S1].\n\n")
            .write(to: document, atomically: true, encoding: .utf8)
        let packet = try prepare(), prompt = try packet.prompt()
        let edition = try block(packet, "**Редакция:"), summary = try block(packet, "Сводка")
        let ok = try packet.resolveEdits(reply(["edits": [
            edit("replace_text", block: edition, match: "3 ноября 2026.** Добавлено [S1].", text: "4 ноября 2026.** Обновлена сводка.", sources: []),
            edit("insert_after", block: summary, text: "Сводка дополнена [S2].\n\n", sources: ["S2"])]]), prompt: prompt, marks: store)
        XCTAssertNil(ok.report.rejection)
        let cited = try packet.resolveEdits(reply(["edits": [
            edit("replace_text", block: edition, match: "3 ноября 2026.**", text: "4 ноября 2026.** [S2]", sources: [])]]), prompt: prompt, marks: store)
        XCTAssertTrue(cited.report.rejection?.contains("no new citations") == true, cited.report.rejection ?? "accepted")
        let other = try packet.resolveEdits(reply(["edits": [edit("insert_after", block: summary, text: "Без источника.\n\n", sources: [])]]),
                                            prompt: prompt, marks: store)
        XCTAssertTrue(other.report.rejection?.contains("must name its packet sources") == true, other.report.rejection ?? "accepted")
    }

    func testDeletedTextIsBoundedAndReportedVerbatim() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let fact = try block(packet, "Старый факт")
        let ok = try packet.resolveEdits(reply(["edits": [edit("replace_text", block: fact, match: "запуск 12 октября [S1]",
            text: "запуск 13 октября [S1] [S2]", sources: ["S2"])]]), prompt: prompt, marks: store)
        XCTAssertNil(ok.report.rejection)
        XCTAssertEqual(ok.report.edits.first?.deleted, "запуск 12 октября [S1]")
        try (text.replacingOccurrences(of: "Старый факт:", with: "Старый факт: " + String(repeating: "очень ", count: 60))).write(to: document, atomically: true, encoding: .utf8)
        let long = try prepare(), longFact = try block(long, "Старый факт")
        let match = try XCTUnwrap(long.blocks.first { $0.id == longFact }).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let refused = try long.resolveEdits(reply(["edits": [edit("replace_text", block: longFact, match: match, text: "Коротко [S1] [S2].", sources: ["S2"])]]),
                                           prompt: long.prompt(), marks: store)
        XCTAssertTrue(refused.report.rejection?.contains("deletes more than 300") == true, refused.report.rejection ?? "")
    }

    func testCitationAloneIsNotCompletionAndUnfinishedWins() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let summary = try block(packet, "Сводка")
        let resolution = try packet.resolveEdits(reply(["edits": [edit("insert_after", block: summary, text: "Одна тема из трёх [S2].\n\n", sources: ["S2"])],
            "unfinished": [["source": "S2", "obstacle": "две другие темы ждут раздела «Семья»"]]]), prompt: prompt, marks: store)
        XCTAssertNil(resolution.report.rejection)
        XCTAssertEqual(outcomes(resolution.report), ["S1": "unmentioned", "S2": "unfinished"])
        XCTAssertTrue(resolution.plan.sourceDecisions.isEmpty, "neither source is acknowledged")
        XCTAssertEqual(resolution.plan.edits.count, 1, "the edit itself still lands")
    }

    func testListsWithoutEditsAreNotTrustedForLargePackets() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let small = try packet.resolveEdits(reply(["done_no_additions": [["source": "S1", "reason": "a"], ["source": "S2", "reason": "b"]]]), prompt: prompt, marks: store)
        XCTAssertEqual(statuses(small.plan), ["S1": "applied", "S2": "noise"])
        XCTAssertFalse(small.report.lazyReply)
        try makeSources(SecretaryPacket.lazyReplyLimit + 1)
        let large = try prepare()
        for key in ["done_no_additions", "unfinished"] {
            let entries = large.selected.map { ["source": $0, "reason": "требует сверки", "obstacle": "требует сверки"] }
            let lazy = try large.resolveEdits(reply([key: entries]), prompt: large.prompt(), marks: store)
            XCTAssertTrue(lazy.report.lazyReply, key)
            XCTAssertTrue(lazy.plan.sourceDecisions.isEmpty)
            XCTAssertEqual(Set(lazy.report.sources.map(\.outcome)), ["unmentioned"])
        }
    }

    private func saveReport(_ report: SecretaryPacket.EditsReport, _ run: String) throws {
        let directory = root.appendingPathComponent("secretary/runs/\(run)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: directory.appendingPathComponent(SecretaryPacket.editsReportName))
    }

    func testCountLimitKeepsCompleteSourceAndLeavesTheRestUnmarked() throws {
        let packet = try SecretaryPacket.prepare(task: task, library: library, marks: store, maxSources: 1)
        XCTAssertEqual(packet.selected.count, 1)
        XCTAssertTrue(store.marks().isEmpty)
        XCTAssertFalse(packet.payload["source_text_truncated"] as? Bool ?? true)
        XCTAssertEqual(Set(try prepare().selected), ["S1", "S2"])
    }

    func testUnfinishedSourceWaitsUntilItsTextSectionOrQueueChanges() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let family = try section(packet, "### Маяк", under: "## Семья")
        let resolution = try packet.resolveEdits(reply(["unfinished": [["source": "S2", "obstacle": "нужен раздел", "section": family]]]), prompt: prompt, marks: store)
        XCTAssertEqual(resolution.report.sources.first { $0.id == "S2" }?.section, "# Документ > ## Семья > ### Маяк")
        try saveReport(resolution.report, "20261031-100000-aaaa")
        let next = try prepare()
        XCTAssertEqual(next.selected, ["S1"])
        XCTAssertEqual(next.hostQueues, SecretaryHostQueues(waitingForText: 0, waitingForViewing: 0, skipped: 0, unfinished: 1))
        XCTAssertFalse(try next.prompt().contains("unfinished_sources"), "host bookkeeping, not model input")
        let retry = try SecretaryPacket.prepare(task: task, library: library, marks: store, retryUnfinished: true)
        XCTAssertEqual(Set(retry.selected), ["S1", "S2"], "explicit retry supplies unchanged evidence without acknowledging it")
        XCTAssertTrue(store.marks().isEmpty)
        // An unrelated section changing does not resend it; the named one does.
        try text.replacingOccurrences(of: "Прочее.", with: "Прочее, обновлено.").write(to: document, atomically: true, encoding: .utf8)
        XCTAssertEqual(try prepare().selected, ["S1"])
        try text.replacingOccurrences(of: "Семейный маяк.", with: "Семейный маяк, обновлено.").write(to: document, atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(try prepare().selected), ["S1", "S2"])
        try text.write(to: document, atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\n- Q1. Ответ пользователя.\n".write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(try prepare().selected), ["S1", "S2"], "a changed review queue re-offers it")
    }

    func testSourceUnmentionedTwiceIsSkippedVisiblyUntilItsTextChanges() throws {
        let packet = try prepare(), prompt = try packet.prompt()
        let resolution = try packet.resolveEdits(reply(["done_no_additions": [["source": "S1", "reason": "повтор"]]]), prompt: prompt, marks: store)
        try saveReport(resolution.report, "20261031-100000-aaaa")
        try saveReport(resolution.report, "20261031-110000-bbbb")
        let next = try prepare()
        XCTAssertEqual(next.selected, ["S1"], "S1 was reviewed (not marked here), S2 went unmentioned twice")
        XCTAssertEqual((next.payload["skipped_sources"] as? [[String: String]])?.first?["source"], "S2")
        XCTAssertEqual(next.hostQueues, SecretaryHostQueues(waitingForText: 0, waitingForViewing: 0, skipped: 1))
        XCTAssertEqual(Set(try SecretaryPacket.prepare(task: task, library: library, marks: store, retryUnfinished: true).selected), ["S1", "S2"])
        try "Заметка 1: новый текст.".write(to: files[1], atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(try prepare().selected), ["S1", "S2"])
    }

    func testImageWithoutReadableTextWaitsForViewing() throws {
        let image = root.appendingPathComponent("recordings/photo.jpg")
        try Data("fixture".utf8).write(to: image)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: image)) { $0["recordingId"] = "photo"; return true }
        let notes = RecallLibrary([library[0], RecallNote(id: "photo", date: Date(), kind: "image", title: nil, summary: nil,
                                                         text: "", filePath: image.path, updated: Date())])
        let packet = try SecretaryPacket.prepare(task: task, library: notes, marks: store)
        XCTAssertEqual(packet.selected, ["S1"])
        XCTAssertEqual(packet.hostQueues, SecretaryHostQueues(waitingForText: 0, waitingForViewing: 1, skipped: 0))
        XCTAssertEqual((packet.payload["viewing_sources"] as? [[String: String]])?.first?["file"], "photo.jpg")
        XCTAssertFalse(SecretaryPacket.waitsForViewing(kind: "image", text: "--- ocr ---\nFinanzamt Bescheid Steuererklärung Antrag"))
        XCTAssertTrue(SecretaryPacket.waitsForViewing(kind: "image", text: "--- ocr ---\nOK 12:30"))
        XCTAssertFalse(SecretaryPacket.waitsForViewing(kind: "audio", text: "--- transcript ---\nOK"))
    }

    func testDispatcherReadsASectionOnceThenAppliesTheWholeJob() async throws {
        let probe = try prepare()
        let family = try section(probe, "### Маяк", under: "## Семья")
        let first = #"{"read_sections":["\#(family)"]}"#
        let second = String(decoding: try JSONSerialization.data(withJSONObject: ["summary": "Маяк",
            "edits": [edit("insert_under_heading", section: family, text: "Эпизод экспорта [S2].", sources: ["S2"])],
            "done_no_additions": [["source": "S1", "reason": "повтор"]]]), as: UTF8.self)
        let fake = EditsFakeExecutor(bodies: [first, second])
        let dispatcher = SecretaryDispatcher(executor: fake, wimmCLI: URL(fileURLWithPath: "/cli"))
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertFalse(execution.isError, execution.error ?? "")
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].prompt.contains("read_sections_supplied"))
        let directory = task.workspace.runDirectory(task.id)
        let result = try JSONDecoder().decode(SecretaryResult.self, from: Data(contentsOf: directory.appendingPathComponent("result.json")))
        XCTAssertEqual(Set(result.sourceDecisions?.map(\.source) ?? []), ["S1", "S2"])
        let report = try JSONDecoder().decode(SecretaryPacket.EditsReport.self, from: Data(contentsOf: directory.appendingPathComponent(SecretaryPacket.editsReportName)))
        XCTAssertEqual(outcomes(report), ["S1": "reviewed", "S2": "used"])
        XCTAssertEqual(try JSONDecoder().decode(SecretaryHostQueues.self, from: Data(contentsOf: directory.appendingPathComponent(SecretaryHostQueues.fileName))),
                       SecretaryHostQueues(waitingForText: 0, waitingForViewing: 0, skipped: 0))
        XCTAssertTrue(try String(contentsOf: document, encoding: .utf8).contains("Семейный маяк.\n\nЭпизод экспорта [S2]."))
        XCTAssertTrue(store.marks().isEmpty, "only the outer verified run finalizes marks")
    }

    // MARK: Status lines

    /// «Маяк» under «Работа» opens with a status line; S1 was recorded on 12 October, S2 on 10 November.
    private func addStatusLine(_ line: String = "**Состояние на 12 октября:** Запуск назначен, экспорта нет [S1] [W1].") throws {
        try text.replacingOccurrences(of: "### Маяк\n\nСтарый факт", with: "### Маяк\n\n\(line)\n\nСтарый факт")
            .write(to: document, atomically: true, encoding: .utf8)
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [String: Any]
        var rows = root["sources"] as! [[String: Any]]
        rows[0]["recorded_at_local"] = "2026-10-12 09:00:00"; rows[1]["recorded_at_local"] = "2026-11-10T17:30:00+01:00"
        root["sources"] = rows
        try JSONSerialization.data(withJSONObject: root).write(to: registry)
    }
    private var november10: String {
        SecretaryPacket.statusDate("2026-11-10", passYear: Calendar(identifier: .gregorian).component(.year, from: Date()))!
    }
    private func statusJob(_ packet: SecretaryPacket, updates: [[String: Any]], extra: [[String: Any]] = []) throws -> [String: Any] {
        ["summary": "Маяк", "edits": [edit("insert_after", block: try block(packet, "Старый факт"),
                                             text: "10 ноября экспорт остаётся планом [S2] [W1].\n\n", sources: ["S2"])] + extra,
         "done_no_additions": [["source": "S1", "reason": "повтор"]], "status_updates": updates]
    }

    func testStatusLabelsAndDates() {
        let dated = SecretaryPacket.statusLabel("**Состояние на 27 октября (долги родителям).** Текст [S1].\n\n")
        XCTAssertEqual(dated?.kind, "Состояние на"); XCTAssertEqual(dated?.suffix, " (долги родителям)")
        XCTAssertEqual(dated?.terminator, "."); XCTAssertEqual(dated?.body, "Текст [S1].")
        XCTAssertEqual(SecretaryPacket.statusLabel("**Итог на 24 октября:** Работа закончилась.")?.kind, "Итог на")
        let plain = SecretaryPacket.statusLabel("**Итог периода:** последняя работа.")
        XCTAssertNil(plain?.kind); XCTAssertEqual(plain?.inner, "Итог периода:")
        XCTAssertNil(SecretaryPacket.statusLabel("**Редакция: 10 ноября 2026.** Правка."))
        XCTAssertNil(SecretaryPacket.statusLabel("Состояние на 5 ноября: без выделения."))
        XCTAssertEqual(SecretaryPacket.statusDate("2026-11-10T17:30:00+01:00", passYear: 2026), "10 ноября")
        XCTAssertEqual(SecretaryPacket.statusDate("2025-02-03 10:00:00", passYear: 2026), "3 февраля 2025")
        XCTAssertNil(SecretaryPacket.statusDate("вчера", passYear: 2026))
    }

    func testEditedTopicNamesItsStatusLineAndTakesAWholeRewriteDatedByTheHost() throws {
        try addStatusLine()
        let packet = try prepare(), prompt = try packet.prompt()
        let status = try block(packet, "**Состояние на")
        let asked = try packet.resolveEdits(reply(try statusJob(packet, updates: [])), prompt: prompt, marks: store)
        XCTAssertNil(asked.report.rejection)
        XCTAssertEqual(asked.report.statusNeeded, [status])
        // The new line drops [S1]; the topic's history still cites it, so nothing is lost. The label repeated by the model is ignored.
        let done = try packet.resolveEdits(reply(try statusJob(packet, updates: [
            ["block": status, "text": "**Состояние на вчера:** Экспорт Markdown остаётся планом [S2] [W1]."]])), prompt: prompt, marks: store)
        XCTAssertNil(done.report.rejection)
        XCTAssertNil(done.report.statusNeeded)
        XCTAssertEqual(done.report.statusUpdates?.map(\.accepted), [true])
        XCTAssertEqual(done.report.statusUpdates?.first?.label, "Состояние на \(november10):")
        XCTAssertTrue(done.report.statusUpdates?.first?.deleted?.contains("Запуск назначен") == true, "the replaced line is kept verbatim")
        XCTAssertTrue(done.plan.summary.contains("строк состояния обновлено 1"), done.plan.summary)
        XCTAssertEqual(outcomes(done.report), ["S1": "reviewed", "S2": "used"])
        _ = try done.packet.apply(done.plan, prompt: prompt, marks: store)
        let written = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(written.contains("### Маяк\n\n**Состояние на \(november10):** Экспорт Markdown остаётся планом [S2] [W1].\n\nСтарый факт: запуск 12 октября [S1].\n\n10 ноября экспорт остаётся планом [S2] [W1]."), written)
    }

    func testRefusedStatusRewriteKeepsTheOldLineAndTheEdits() throws {
        try addStatusLine()
        let packet = try prepare(), prompt = try packet.prompt()
        let status = try block(packet, "**Состояние на"), other = try block(packet, "Прочее.")
        func reason(_ update: [String: Any]) throws -> String {
            let result = try packet.resolveEdits(reply(try statusJob(packet, updates: [update])), prompt: prompt, marks: store)
            XCTAssertNil(result.report.rejection); XCTAssertEqual(result.report.edits.count, 1, "the edit stands")
            XCTAssertEqual(result.report.statusNeeded, [status])
            XCTAssertFalse(result.plan.edits.contains { $0.operation == "replace_block" })
            return result.report.statusUpdates?.first?.reason ?? "accepted"
        }
        XCTAssertTrue(try reason(["block": status, "text": "Экспорт запущен [S2] [W1] [S7]."]).contains("cites S7"))
        XCTAssertTrue(try reason(["block": status, "text": String(repeating: "Длинно. ", count: 120) + "[S2] [W1]"]).contains("longer than"))
        XCTAssertTrue(try reason(["block": status, "text": "Первый абзац [S2] [W1].\n\nВторой."]).contains("one paragraph"))
        XCTAssertTrue(try reason(["block": status, "text": "Экспорт остаётся планом [W1]."]).contains("no source with a known date"))
        XCTAssertTrue(try reason(["block": other, "text": "Не строка состояния [S2]."]).contains("not the status line"))
    }

    func testStatusRewriteMayNotDropAReferenceTheTopicLosesWithIt() throws {
        try addStatusLine("**Состояние на 12 октября:** Запуск назначен [S1] [U3].")
        let packet = try prepare(), prompt = try packet.prompt()
        let status = try block(packet, "**Состояние на")
        let result = try packet.resolveEdits(reply(try statusJob(packet, updates: [["block": status, "text": "Экспорт остаётся планом [S2]."]])),
                                             prompt: prompt, marks: store)
        XCTAssertTrue(result.report.statusUpdates?.first?.reason?.contains("drops U3") == true, result.report.statusUpdates?.first?.reason ?? "accepted")
    }

    func testStatusRewriteMayNotDropAnOrdinaryLinkTheTopicLosesWithIt() throws {
        try addStatusLine("**Состояние на 12 октября:** Запуск назначен [S1] [W1]. Подробности — в [истории](wimm/history.md).")
        let packet = try prepare(), prompt = try packet.prompt()
        let status = try block(packet, "**Состояние на")
        let dropped = try packet.resolveEdits(reply(try statusJob(packet, updates: [["block": status, "text": "Экспорт остаётся планом [S2] [W1]."]])),
                                              prompt: prompt, marks: store)
        XCTAssertTrue(dropped.report.statusUpdates?.first?.reason?.contains("drops the link wimm/history.md") == true,
                      dropped.report.statusUpdates?.first?.reason ?? "accepted")
        XCTAssertNil(dropped.report.rejection)
        let kept = try packet.resolveEdits(reply(try statusJob(packet, updates: [["block": status,
            "text": "Экспорт остаётся планом [S2] [W1]. Подробности — в [истории](wimm/history.md)."]])), prompt: prompt, marks: store)
        XCTAssertEqual(kept.report.statusUpdates?.first?.accepted, true, kept.report.statusUpdates?.first?.reason ?? "")
        XCTAssertEqual(SecretaryPacket.linkTargets("<a id=\"car\"></a> и [раздел](#work), [S1]"), ["car", "#work"])
    }

    func testStatusRewriteSitsBesideAnInsertionAfterTheSameLine() throws {
        try addStatusLine()
        let packet = try prepare(), prompt = try packet.prompt()
        let status = try block(packet, "**Состояние на")
        let job: [String: Any] = ["summary": "Маяк", "edits": [edit("insert_after", block: status, text: "Сразу после строки [S2] [W1].\n\n", sources: ["S2"])],
            "done_no_additions": [["source": "S1", "reason": "повтор"]],
            "status_updates": [["block": status, "text": "Экспорт остаётся планом [S2] [W1]."]]]
        let result = try packet.resolveEdits(reply(job), prompt: prompt, marks: store)
        XCTAssertNil(result.report.rejection)
        _ = try result.packet.apply(result.plan, prompt: prompt, marks: store)
        XCTAssertTrue(try String(contentsOf: document, encoding: .utf8)
            .contains("**Состояние на \(november10):** Экспорт остаётся планом [S2] [W1].\n\nСразу после строки [S2] [W1].\n\nСтарый факт"))
    }

    func testEditorsOwnPatchOfTheStatusLineNeedsNoRefresh() throws {
        try addStatusLine()
        let packet = try prepare(), prompt = try packet.prompt()
        let status = try block(packet, "**Состояние на")
        let result = try packet.resolveEdits(reply(["edits": [edit("replace_text", block: status, match: "экспорта нет [S1]",
            text: "экспорт остаётся планом [S1] [S2]", sources: ["S2"])], "done_no_additions": [["source": "S1", "reason": "повтор"]]]),
            prompt: prompt, marks: store)
        XCTAssertNil(result.report.rejection, result.report.rejection ?? "")
        XCTAssertNil(result.report.statusNeeded)
    }

    func testDispatcherAsksForStatusLinesInASeparateShortRequest() async throws {
        try addStatusLine()
        let probe = try prepare()
        let status = try block(probe, "**Состояние на")
        let main = String(decoding: try JSONSerialization.data(withJSONObject: try statusJob(probe, updates: [])), as: UTF8.self)
        let refresh = #"{"status_updates":[{"block":"\#(status)","text":"Экспорт Markdown остаётся планом [S2] [W1]."}]}"#
        let fake = EditsFakeExecutor(bodies: [main, refresh])
        let dispatcher = SecretaryDispatcher(executor: fake, wimmCLI: URL(fileURLWithPath: "/cli"))
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertFalse(execution.isError, execution.error ?? "")
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].systemPrompt, SecretaryPacket.statusContract)
        XCTAssertTrue(requests[1].prompt.contains("status_refresh") && requests[1].prompt.contains("10 ноября экспорт остаётся планом"))
        XCTAssertFalse(requests[1].prompt.contains("Заметка 1"), "the status request carries no sources")
        XCTAssertLessThan(requests[1].prompt.utf8.count, 2_000)
        XCTAssertEqual(execution.costUSD ?? 0, 0.02, accuracy: 0.0001, "both paid requests are counted")
        XCTAssertTrue(execution.finalText?.contains("\"edits\"") == true, "the run's reply stays the main one")
        let written = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(written.contains("**Состояние на \(november10):** Экспорт Markdown остаётся планом [S2] [W1]."), written)
        XCTAssertTrue(written.contains("10 ноября экспорт остаётся планом [S2] [W1]."))
    }

    func testDispatcherAppliesTheEditsWhenTheStatusReplyIsUnusable() async throws {
        try addStatusLine()
        let probe = try prepare()
        let main = String(decoding: try JSONSerialization.data(withJSONObject: try statusJob(probe, updates: [])), as: UTF8.self)
        let fake = EditsFakeExecutor(bodies: [main, "не JSON"])
        let dispatcher = SecretaryDispatcher(executor: fake, wimmCLI: URL(fileURLWithPath: "/cli"))
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertFalse(execution.isError, execution.error ?? "")
        let written = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(written.contains("**Состояние на 12 октября:** Запуск назначен, экспорта нет [S1] [W1]."), "the old line stays")
        XCTAssertTrue(written.contains("10 ноября экспорт остаётся планом [S2] [W1]."), "the edit is applied")
    }

    func testMissingSectionsNameTheTargetsSectionOnce() throws {
        let packet = try prepare()
        var input = try JSONSerialization.jsonObject(with: Data(packet.prompt().utf8)) as! [String: Any]
        let family = try section(packet, "### Маяк", under: "## Семья"), familyText = try block(packet, "Семейный маяк")
        input["document_blocks"] = (input["document_blocks"] as! [[String: String]]).filter { $0["id"] != familyText }
        let narrow = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let body = try reply(["edits": [
            edit("insert_under_heading", section: family, text: "a [S2].", sources: ["S2"]),
            edit("insert_after", block: familyText, text: "b [S2].\n\n", sources: ["S2"]),
            edit("insert_after", block: try block(packet, "Сводка"), text: "c [S2].\n\n", sources: ["S2"])]])
        XCTAssertEqual(packet.missingSections(body, prompt: narrow), [family])
        XCTAssertEqual(packet.missingSections(body, prompt: try packet.prompt()), [])
    }

    func testDispatcherReadsAnUnsuppliedTargetSectionInsteadOfRejecting() async throws {
        // A document large enough that a late section stays out of the 50 KB context.
        let filler = (0..<120).map { "Архивный абзац \($0): " + String(repeating: "старое событие без связи ", count: 20) + "\n\n" }.joined()
        try (text.replacingOccurrences(of: "[S1]: ../recordings/n0.meta.json", with: "## Архив\n\n" + filler
            + "## Поздний раздел\n\nДальний абзац.\n\n[S1]: ../recordings/n0.meta.json")).write(to: document, atomically: true, encoding: .utf8)
        let probe = try prepare()
        let late = try section(probe, "## Поздний раздел")
        XCTAssertFalse(try probe.prompt().contains("Дальний абзац"), "precondition: the late section is not supplied")
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["edits": [
            edit("insert_under_heading", section: late, text: "Поздний эпизод [S2].", sources: ["S2"])],
            "done_no_additions": [["source": "S1", "reason": "повтор"]]]), as: UTF8.self)
        let fake = EditsFakeExecutor(bodies: [body, body])
        var dispatcher = SecretaryDispatcher(executor: fake, wimmCLI: URL(fileURLWithPath: "/cli"))
        dispatcher.model = "claude-haiku-5-5"
        let execution = try await dispatcher.runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertFalse(execution.isError, execution.error ?? "")
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].prompt.contains("Дальний абзац") && requests[1].prompt.contains("host_note"))
        XCTAssertEqual(requests.map(\.effort), ["high", "high"], "format-2 Haiku packets reason at effort high")
        XCTAssertTrue(try String(contentsOf: document, encoding: .utf8).contains("Дальний абзац.\n\nПоздний эпизод [S2]."))
    }

    func testPacketEffortDefaultsOnlyForHaiku() {
        var dispatcher = SecretaryDispatcher(executor: EditsFakeExecutor(bodies: ["{}"]), wimmCLI: URL(fileURLWithPath: "/cli"))
        XCTAssertNil(dispatcher.packetEffort(), "unknown model keeps the agent default")
        dispatcher.model = "claude-haiku-5-5"
        XCTAssertEqual(dispatcher.packetEffort(), "high")
        dispatcher.model = "claude-sonnet-5-5"
        XCTAssertNil(dispatcher.packetEffort())
        dispatcher.effort = "medium"; dispatcher.model = "claude-haiku-5-5"
        XCTAssertEqual(dispatcher.packetEffort(), "medium", "an explicit effort wins")
    }

    func testDispatcherRefusesARejectedJobWithoutWriting() async throws {
        let probe = try prepare(), fact = try block(probe, "Старый факт")
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["edits": [
            edit("replace_block", block: fact, text: "Всё заново [S2].", sources: ["S2"])]]), as: UTF8.self)
        let before = try Data(contentsOf: document)
        let execution = try await SecretaryDispatcher(executor: EditsFakeExecutor(bodies: [body]), wimmCLI: URL(fileURLWithPath: "/cli"))
            .runPacket(task: task, library: library, marks: store, onEvent: { _ in })
        XCTAssertTrue(execution.isError)
        XCTAssertEqual(try Data(contentsOf: document), before)
        let report = try JSONDecoder().decode(SecretaryPacket.EditsReport.self, from: Data(contentsOf: task.workspace.runDirectory(task.id).appendingPathComponent(SecretaryPacket.editsReportName)))
        XCTAssertFalse(report.accepted)
        XCTAssertEqual(Set(report.sources.map(\.outcome)), ["rejected"], "counts toward the skipped list")
    }

    func testPacketOnlyWithOpenCommentsExportsOneFileAndAllowsOnlyDryRun() async throws {
        let comments = DocumentCommentStore(document: document)
        try await comments.append(comments.newRoot(kind: .comment,
            selector: TextQuoteSelector(quote: "Старый факт", prefix: "", suffix: ""), section: nil, heading: "Маяк", text: "Проверить"))
        let note = String(repeating: "Текст заметки. ", count: 1_200)
        try note.write(to: files[0], atomically: true, encoding: .utf8)
        let cli = URL(fileURLWithPath: "/unused-cli")
        do {
            _ = try await SecretaryPacketFiles.prepare(document: document, cli: cli, sourceKB: 64,
                                                        library: library, marks: store)
            XCTFail("Ordinary preparation should require resolving open comments")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Open comment threads"))
        }
        let data = try await SecretaryPacketFiles.prepare(document: document, cli: cli, sourceKB: 64,
                                                           library: library, marks: store, packetOnly: true)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["dry_run_only"] as? Bool, true)
        let id = try XCTUnwrap(manifest["run_id"] as? String)
        let order = try XCTUnwrap(manifest["read_order"] as? [String])
        XCTAssertEqual(order.count, 1)
        let packet = try String(contentsOfFile: XCTUnwrap(order.first), encoding: .utf8)
        XCTAssertGreaterThan(packet.utf8.count, SecretaryPacketFiles.packetPageBytes)
        XCTAssertTrue(packet.contains(note.trimmingCharacters(in: .whitespaces)))
        let body = Data(#"{"done_no_additions":[{"source":"S1","reason":"повтор"}]}"#.utf8)
        let preview = try await SecretaryPacketFiles.apply(runID: id, response: body, dryRun: true,
                                                            marks: store, recordings: { self.files })
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: preview) as? [String: Any])
        XCTAssertEqual(report["accepted"] as? Bool, true)
        XCTAssertEqual(report["committed"] as? Bool, false)
        do {
            _ = try await SecretaryPacketFiles.apply(runID: id, response: body, marks: store, recordings: { self.files })
            XCTFail("Packet-only runs must never commit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("apply --dry-run"))
        }
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), text)
        let threads = try await comments.load().threads
        XCTAssertEqual(threads.filter { $0.status == .open }.count, 1)
    }

    #if os(macOS)
    func testCodexSendsVersionedPagesAndValidatesWithoutApplying() async throws {
        let key = "sk-proj-abc123456789012345678901"
        let note = String(repeating: "План Маяк. ", count: 6_000)
        try (note + "\nOPENAI_API_KEY=" + key).write(to: files[0], atomically: true, encoding: .utf8)
        let data = try await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
            sourceKB: 128, library: library, marks: store, packetOnly: true)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(manifest["run_id"] as? String)
        _ = try SecretaryPacketFiles.read(runID: id, operation: "section", query: "Семья",
            library: library, marks: store)
        let binary = root.appendingPathComponent("fake-codex")
        try #"""
        #!/bin/sh
        set -eu
        case " $* " in *" --ephemeral "*) ;; *) exit 2 ;; esac
        case " $* " in *" -s read-only "*) ;; *) exit 2 ;; esac
        case " $* " in *" features.shell_tool=false "*" - ") ;; *) exit 2 ;; esac
        cat > received.md
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"done_no_additions\":[{\"source\":\"S1\",\"reason\":\"повтор\"}]}"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":42,"output_tokens":8}}'
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let executor = CodexExecutor(binary: binary)
        do {
            _ = try await SecretaryPacketFiles.codex(runID: id, executor: executor, commit: true,
                model: "fixture", effort: "medium", marks: store)
            XCTFail("Packet-only sessions must refuse apply before sending")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("without --packet-only"))
        }
        let registryBefore = try Data(contentsOf: registry)
        let result = try await SecretaryPacketFiles.codex(runID: id, executor: executor,
            model: "fixture", effort: "medium", marks: store)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let validation = try XCTUnwrap(report["validation"] as? [String: Any])
        XCTAssertEqual(validation["accepted"] as? Bool, true)
        XCTAssertEqual(validation["committed"] as? Bool, false)
        XCTAssertEqual(validation["reviewed_sources"] as? [String], ["S1"])
        let usage = try XCTUnwrap(validation["usage"] as? [String: Any])
        XCTAssertEqual(usage["tokens_in"] as? Int, 42)
        let response = URL(fileURLWithPath: try XCTUnwrap(report["response"] as? String))
        let prompt = try String(contentsOf: response.deletingLastPathComponent().appendingPathComponent("received.md"), encoding: .utf8)
        let source = try XCTUnwrap(prompt.range(of: "===== источник S1 ====="))
        let context = try XCTUnwrap(prompt.range(of: "## Блоки документа"))
        XCTAssertLessThan(source.lowerBound, context.lowerBound)
        XCTAssertTrue(prompt.contains(note))
        XCTAssertTrue(prompt.contains("Семейный маяк."))
        XCTAssertTrue(prompt.contains("OPENAI_API_KEY=[скрыто]"))
        XCTAssertFalse(prompt.contains(key))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), text)
        XCTAssertEqual(try Data(contentsOf: registry), registryBefore)
        XCTAssertTrue(store.marks().isEmpty)
    }
    #endif

    func testFileWorkflowAppliesFormatTwoAndDryRunWritesNothing() async throws {
        let manifest = try JSONSerialization.jsonObject(with: await SecretaryPacketFiles.prepare(document: document,
            cli: URL(fileURLWithPath: "/unused-cli"), sourceKB: 64, library: library, marks: store)) as! [String: Any]
        let id = manifest["run_id"] as! String
        XCTAssertEqual(manifest["response_format"] as? Int, 2)
        XCTAssertNotNil(manifest["host_queues"])
        let policyURL = URL(fileURLWithPath: try XCTUnwrap(manifest["policy"] as? String))
        let policy = try String(contentsOf: policyURL, encoding: .utf8)
        XCTAssertTrue(policy.contains("secretary read RUN --section"))
        XCTAssertFalse(policy.contains(#""read_sections""#))
        XCTAssertFalse(policy.contains("no tool call is available"))
        let schemaURL = URL(fileURLWithPath: try XCTUnwrap(manifest["schema"] as? String))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["summary", "edits", "done_no_additions", "unfinished", "not_a_note", "questions", "status_updates"])
        XCTAssertFalse((schema["required"] as? [String] ?? []).contains("nothing_to_add"))
        let edits = try XCTUnwrap(properties["edits"] as? [String: Any])
        let editItems = try XCTUnwrap(edits["items"] as? [String: Any])
        let editProperties = try XCTUnwrap(editItems["properties"] as? [String: Any])
        XCTAssertNotNil(editProperties["section"])
        XCTAssertNotNil(editProperties["sources"])
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest["input"] as! String))) as! [String: Any]
        let outline = input["outline"] as! [[String: String]]
        let family = try XCTUnwrap(outline.last { $0["title"] == "### Маяк" }?["id"])
        let readOrder = try XCTUnwrap(manifest["read_order"] as? [String])
        let pages = try readOrder.map { try String(contentsOfFile: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(pages.contains("## Источники в этой порции"))
        XCTAssertFalse(pages.contains("Прежде: "))
        let documentContext = try XCTUnwrap(pages.range(of: "## Очередь вопросов"))
        for id in ["S1", "S2"] {
            let source = try XCTUnwrap(pages.range(of: "===== конец источника \(id) ====="))
            XCTAssertLessThan(source.upperBound, documentContext.lowerBound)
        }
        let path = "Раздел `\(family)` · Документ → Семья → Маяк"
        XCTAssertEqual(pages.components(separatedBy: path).count, 2)
        XCTAssertTrue(pages.contains("Семейный маяк."))
        let body = try JSONSerialization.data(withJSONObject: ["summary": "x",
            "edits": [edit("insert_under_heading", section: family, text: "Новый эпизод [S2].", sources: ["S2"])],
            "done_no_additions": [["source": "S1", "reason": "повтор"]]])
        let before = try Data(contentsOf: document)
        let fact = try block(prepare(), "Старый факт")
        let mixed = try JSONSerialization.data(withJSONObject: ["edits": [
            edit("insert_under_heading", section: family, text: "Новый эпизод [S2].", sources: ["S2"]),
            edit("replace_text", block: fact, match: "Фразы нет в блоке.", text: "Новый факт [S1].", sources: ["S1"])
        ]])
        let mixedData = try await SecretaryPacketFiles.apply(
            runID: id, response: mixed, dryRun: true, marks: store, recordings: { self.files })
        let mixedPreview = try XCTUnwrap(JSONSerialization.jsonObject(with: mixedData) as? [String: Any])
        XCTAssertEqual(mixedPreview["accepted"] as? Bool, true)
        XCTAssertEqual(mixedPreview["used_sources"] as? [String], ["S2"])
        XCTAssertEqual(mixedPreview["queued_sources"] as? [String], ["S1"])
        let rejected = try XCTUnwrap(mixedPreview["rejected_edits"] as? [[String: Any]])
        XCTAssertEqual(rejected.map { $0["index"] as? Int }, [1])
        XCTAssertTrue((rejected.first?["reason"] as? String)?.contains("match is absent") == true)
        let preview = try JSONSerialization.jsonObject(with: await SecretaryPacketFiles.apply(runID: id, response: body, dryRun: true,
            marks: store, recordings: { self.files })) as! [String: Any]
        XCTAssertEqual(preview["used_sources"] as? [String], ["S2"])
        XCTAssertEqual(try Data(contentsOf: document), before)
        let applied = try await SecretaryPacketFiles.apply(runID: id, response: body, marks: store, recordings: { self.files })
        let report = try JSONSerialization.jsonObject(with: applied) as! [String: Any]
        XCTAssertEqual(report["findings"] as? [String], [], String(decoding: applied, as: UTF8.self))
        XCTAssertEqual(Set(report["stored_sources"] as? [String] ?? []), ["S1", "S2"])
        let timings = try XCTUnwrap(report["timings_ms"] as? [String: Double])
        let stages = ["verification", "registry_validation", "receipt_validation", "registry_update_plan",
                      "citation_repair_plan", "registry_and_document_write", "mark_write",
                      "final_document_check", "bookkeeping_finalize", "queue_scan"]
        let subtotal = try stages.map { try XCTUnwrap(timings[$0], $0) }.reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(timings["bookkeeping"]), subtotal, accuracy: 0.001)
        XCTAssertTrue(try String(contentsOf: document, encoding: .utf8).contains("Семейный маяк.\n\nНовый эпизод [S2].\n\n"))
        let replay = try await SecretaryPacketFiles.apply(runID: id, response: body, marks: store, recordings: { self.files })
        XCTAssertEqual(replay, applied)
    }
}

private actor EditsFakeExecutor: SecretaryExecutor {
    nonisolated let name = "claude-code"
    let bodies: [String]
    var requests: [SecretaryExecutionRequest] = []
    init(bodies: [String]) { self.bodies = bodies }
    func run(_ request: SecretaryExecutionRequest, onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        requests.append(request)
        return SecretaryExecution(exitStatus: 0, finalText: bodies[min(requests.count - 1, bodies.count - 1)], costUSD: 0.01,
                                  tokensIn: 100, tokensOut: 10, turns: 1)
    }
}
