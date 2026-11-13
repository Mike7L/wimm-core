import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

/// Format 2 (2026-11-03): a source above the solo limit is offered as a labeled partial preview
/// whose only outcome is "not a note" → noise; anything else rejects the reply or leaves it blocked.
final class SecretaryPacketPreviewTests: XCTestCase {
    private var root: URL!
    private var marks: AgentMarkStore!
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registry: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }
    private var big: URL { root.appendingPathComponent("recordings/app.txt") }
    private var short: URL { root.appendingPathComponent("recordings/short.txt") }
    private var included: [URL] = []
    private var files: [URL] { included }
    private let originalDocument = "# Документ\n\n## Переписка\n\nСтарое.\n\n"
    private var library: RecallLibrary {
        RecallLibrary(included.enumerated().map { i, file in
            RecallNote(id: "n\(i)", date: Date(timeIntervalSince1970: 1_700_000_000), kind: "text", title: nil, summary: nil,
                       text: "cache", filePath: file.path, updated: Date())
        })
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("packet-preview-\(UUID().uuidString)")
        for path in ["docs", "recordings", "secretary/protocol"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        marks = AgentMarkStore(directory: root.appendingPathComponent("state"))
        try originalDocument.write(to: document, atomically: true, encoding: .utf8)
        try "Старый протокол.".write(to: root.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "Пиши только сказанное.".write(to: root.appendingPathComponent(SecretaryPacket.editsPolicyPath), atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\nНет.\n".write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["sources": [], "source_count": 0, "counts": [String: Int](), "batches": []]).write(to: registry)
        // About 216 KB of log lines: above the 128 KB solo limit of a 64 KB packet.
        let lines = (0..<240).map { "2026-07-19 09:\(String(format: "%03d", $0)) [info] growthbook refresh " + String(repeating: "ж", count: 420) }
        try (lines.joined(separator: "\n") + "\n").write(to: big, atomically: true, encoding: .utf8)
        try "Короткая заметка: Вера звонила.".write(to: short, atomically: true, encoding: .utf8)
        for (file, id) in [(big, "app"), (short, "short")] {
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { $0["recordingId"] = id; return true }
        }
        included = [big, short]
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func prepare() async throws -> (id: String, manifest: [String: Any], input: [String: Any]) {
        let m = try object(await SecretaryPacketFiles.prepare(document: document, cli: URL(fileURLWithPath: "/unused-cli"),
                                                              sourceKB: 64, library: library, marks: marks))
        return (m["run_id"] as! String, m, try object(Data(contentsOf: URL(fileURLWithPath: m["input"] as! String))))
    }
    private func apply(_ id: String, _ reply: [String: Any], dryRun: Bool = false) async throws -> [String: Any] {
        try object(await SecretaryPacketFiles.apply(runID: id, response: JSONSerialization.data(withJSONObject: reply),
                                                    dryRun: dryRun, marks: marks, recordings: { self.files }))
    }
    private func ids(_ input: [String: Any]) -> (preview: String, source: String) {
        ((input["oversize_previews"] as! [[String: Any]])[0]["source"] as! String,
         (input["sources"] as! [[String: Any]])[0]["source"] as! String)
    }
    private func row(_ id: String) throws -> [String: Any]? {
        (try object(Data(contentsOf: registry))["sources"] as? [[String: Any]])?.first { $0["source_id"] as? String == id }
    }

    func testOversizeSourceIsOfferedAsLabeledPreviewNotAsSource() async throws {
        let before = try Data(contentsOf: registry)
        let (_, manifest, input) = try await prepare()
        let previews = try XCTUnwrap(input["oversize_previews"] as? [[String: Any]])
        XCTAssertEqual(previews.count, 1)
        let preview = previews[0], (id, source) = ids(input)
        XCTAssertEqual(preview["file"] as? String, "app.txt")
        XCTAssertEqual(preview["kind"] as? String, "text")
        XCTAssertGreaterThan(preview["total_bytes"] as! Int, 128_000)
        XCTAssertTrue((preview["label"] as? String)?.contains("PARTIAL VIEW") == true)
        XCTAssertTrue((preview["head"] as? String)?.contains("09:000") == true)
        XCTAssertTrue((preview["tail"] as? String)?.contains("09:239") == true)
        XCTAssertLessThan((preview["head"] as! String).utf8.count + (preview["tail"] as! String).utf8.count, 5_000)
        // The short note is the packet's one real source; the preview is not among the sources.
        XCTAssertNotEqual(id, source)
        XCTAssertEqual((input["sources"] as? [Any])?.count, 1)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self).contains("09:120"))
        let blocked = try XCTUnwrap(manifest["blocked_sources"] as? [[String: String]])
        XCTAssertEqual(blocked.first?["source"], id)
        XCTAssertTrue(blocked.first?["reason"]?.contains("partial preview") == true)
        XCTAssertEqual(manifest["oversize_previews"] as? [String], [id])
        let compact = try object(SecretaryPacketFiles.compactPrepareOutput(JSONSerialization.data(withJSONObject: manifest)))
        XCTAssertNil(compact["blocked_sources"])
        XCTAssertNil(compact["no_text_sources"])
        XCTAssertNotNil(compact["host_queues"])
        let manifestURL = URL(fileURLWithPath: try XCTUnwrap(compact["manifest"] as? String))
        XCTAssertNotNil(try object(Data(contentsOf: manifestURL))["blocked_sources"])
        let order = try XCTUnwrap(compact["read_order"] as? [String])
        let pages = try order.map { try String(contentsOfFile: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(pages.contains("oversize-previews.md"))
        XCTAssertTrue(pages.contains("〔b"))
        XCTAssertFalse(pages.contains("----- конец блока"))
        XCTAssertFalse(pages.contains("## Прочие поля input.json"))
        XCTAssertFalse(pages.contains("09:000"), "optional previews stay outside the main read order")
        let previewPage = manifestURL.deletingLastPathComponent().appendingPathComponent("oversize-previews.md")
        let previewText = try String(contentsOf: previewPage, encoding: .utf8)
        XCTAssertTrue(previewText.contains("09:000"))
        XCTAssertTrue(previewText.contains("09:239"))
        XCTAssertTrue((try String(contentsOf: URL(fileURLWithPath: manifest["policy"] as! String), encoding: .utf8)).contains("not_a_note"))
        XCTAssertEqual(try Data(contentsOf: registry), before)
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testPreviewOnlyQueueStillPrepares() async throws {
        included = [big]
        let (_, manifest, input) = try await prepare()
        let order = try XCTUnwrap(manifest["read_order"] as? [String])
        let pages = try order.map { try String(contentsOfFile: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(pages.contains("09:000"))
        XCTAssertTrue(pages.contains("09:239"))
        XCTAssertEqual((input["sources"] as? [Any])?.count, 0)
        XCTAssertEqual((input["oversize_previews"] as? [Any])?.count, 1)
    }

    func testNotANoteYieldsNoiseWithPartialViewReason() async throws {
        let (run, _, input) = try await prepare()
        let (id, source) = ids(input)
        let report = try await apply(run, ["edits": [], "done_no_additions": [["source": source, "reason": "ничего нового"]],
                                           "not_a_note": [["source": id, "reason": "журнал приложения"]]])
        XCTAssertEqual(report["findings"] as? [String], [])
        XCTAssertEqual((report["previews"] as? [[String: String]])?.first?["outcome"], "not_a_note")
        let noise = try XCTUnwrap(row(id))
        XCTAssertEqual(noise["status"] as? String, "noise")
        XCTAssertTrue((noise["reason"] as? String)?.hasPrefix("partial view:") == true)
        XCTAssertEqual(noise["read_scope"] as? String, "partial_view")
        XCTAssertEqual(noise["primary_text_read"] as? Bool, false)
        XCTAssertEqual(marks.marks()["app.txt"]?.status, .noise)
        XCTAssertEqual(marks.marks()["app.txt"]?.source, id)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), originalDocument)
    }

    func testEditsAndOtherOutcomesForAPreviewRejectTheReply() async throws {
        let (run, _, input) = try await prepare()
        let (id, source) = ids(input)
        let heading = try XCTUnwrap((input["outline"] as? [[String: String]])?.first { $0["title"] == "## Переписка" }?["id"])
        func edit(_ text: String, _ sources: [String]) -> [String: Any] {
            ["operation": "insert_under_heading", "section": heading, "text": text, "sources": sources]
        }
        let replies: [[String: Any]] = [
            ["edits": [edit("Лог [\(id)].", [id])]],
            ["edits": [edit("Звонок [\(source)], см. [\(id)].", [source])]],
            ["edits": [], "done_no_additions": [["source": id, "reason": "прочитано"]]],
            ["edits": [], "unfinished": [["source": id, "obstacle": "слишком длинно"]]],
            ["edits": [edit("Лог [\(id)].", [id])], "not_a_note": [["source": id, "reason": "лог"]]],
        ]
        for reply in replies {
            let report = try await apply(run, reply, dryRun: true)
            XCTAssertEqual(report["accepted"] as? Bool, false, "\(reply)")
            XCTAssertEqual((report["previews"] as? [[String: String]])?.first?["outcome"], "left_blocked")
        }
        // Registry revision and bookkeeping accept nothing but noise from a partial view.
        let state = try SecretaryPacketFiles.load(run, marks: marks)
        let receipt = try XCTUnwrap(state.previewReceipts?[id])
        XCTAssertNotNil(receipt.partialView); XCTAssertFalse(receipt.wholeTextSupplied)
        for status in ["applied", "pending", "duplicate", "failed"] {
            XCTAssertThrowsError(try SecretaryRegistryRevision.revised(["source_id": id, "status": "pending"],
                decision: .init(source: id, status: status, reason: "x", mergedWith: status == "duplicate" ? [source] : nil),
                receipt: receipt, task: state.packet().task, known: [id, source]))
        }
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), originalDocument)
        XCTAssertTrue(marks.marks().isEmpty)
    }

    func testUntouchedPreviewStaysBlockedAndIsReported() async throws {
        var (run, _, input) = try await prepare()
        let (id, source) = ids(input)
        let report = try await apply(run, ["edits": [], "done_no_additions": [["source": source, "reason": "ничего нового"]]])
        XCTAssertEqual(report["findings"] as? [String], [])
        XCTAssertEqual(report["previews"] as? [[String: String]], [["source": id, "file": "app.txt", "outcome": "left_blocked", "reason": ""]])
        XCTAssertNil(marks.marks()["app.txt"])
        XCTAssertNotNil(marks.marks()["short.txt"])
        XCTAssertNil(try row(id), "an unused preview reserved an S id")
        (run, _, input) = try await prepare()
        XCTAssertEqual(((input["oversize_previews"] as? [[String: Any]])?.first?["file"]) as? String, "app.txt")
    }
}
