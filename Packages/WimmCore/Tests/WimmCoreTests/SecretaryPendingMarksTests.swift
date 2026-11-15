import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

/// `wimm-cli secretary pending`: pending marks of deleted notes are reported and closed
/// only on proof; a cited pending source is reported, never re-marked.
final class SecretaryPendingMarksTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("library/Recordings") }
    private var trash: URL { root.appendingPathComponent("library/Trash") }
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var store: AgentMarkStore { AgentMarkStore(directory: root.appendingPathComponent("library/AgentState")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-marks-\(UUID().uuidString)")
        for dir in [library, trash, root.appendingPathComponent("docs"), root.appendingPathComponent("secretary/runs")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "".write(to: root.appendingPathComponent("secretary/threads.jsonl"), atomically: true, encoding: .utf8)
        for name in ["live.m4a", "cited.m4a", "ahead.m4a"] { try Data([1]).write(to: library.appendingPathComponent(name)) }
        // Trashed under its own name, and under a free base name with the marker naming it.
        try Data([1]).write(to: trash.appendingPathComponent("binned.m4a"))
        try Data([1]).write(to: trash.appendingPathComponent("renamed 2.m4a"))
        try JSONSerialization.data(withJSONObject: ["trashed": true, "originalPath": "/x/Recordings/renamed.m4a"])
            .write(to: trash.appendingPathComponent("renamed 2.meta.json"))
        try Data([1]).write(to: trash.appendingPathComponent("loose.m4a"))

        try "# Doc\n\nБабушка ждёт осенью. [S2]\n\n[S2]: ../recordings/cited.meta.json\n[S6]: ../recordings/gone.meta.json\n"
            .write(to: document, atomically: true, encoding: .utf8)
        let sources: [[String: Any]] = [
            row("S1", "live.m4a"), row("S2", "cited.m4a"), row("S3", "ahead.m4a", status: "applied"),
            row("S4", "binned.m4a", removed: true), row("S5", "renamed.m4a"), row("S6", "gone.m4a"),
        ]
        var counts: [String: Int] = [:]
        for source in sources { counts[source["status"] as! String, default: 0] += 1 }
        try JSONSerialization.data(withJSONObject: ["sources": sources, "source_count": sources.count, "counts": counts])
            .write(to: document.deletingPathExtension().appendingPathExtension("sources.json"))

        var marks: [String: AgentMarkStore.Mark?] = [:]
        for (file, source) in [("live.m4a", "S1"), ("cited.m4a", "S2"), ("ahead.m4a", "S3"), ("binned.m4a", "S4"),
                               ("renamed.m4a", "S5"), ("gone.m4a", "S6")] {
            marks[file] = mark(source)
        }
        marks["loose.m4a"] = mark(nil)          // set through MCP by hand, note now in Trash
        marks["done.m4a"] = mark("S9", .applied) // not pending: never looked at
        try store.update(marks)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func row(_ id: String, _ file: String, status: String = "pending", removed: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["source_id": id, "path": "../recordings/\((file as NSString).deletingPathExtension).meta.json",
                                  "note_file": file, "status": status]
        if removed { row["removed_from_wimm"] = ["date": "2026-11-01", "reason": "Confirmed deleted in Wimm Trash"] }
        return row
    }

    private func mark(_ source: String?, _ status: AgentMarkStore.Mark.Status = .pending) -> AgentMarkStore.Mark {
        .init(status: status, source: source, markedAt: Date(timeIntervalSince1970: 1_790_000_000),
              noteId: UUID().uuidString, text: "t", analysis: "a")
    }

    private func audit(apply: Bool) throws -> SecretaryPendingMarks.Report {
        try SecretaryPendingMarks.audit(document: document, apply: apply, store: store, active: library, trash: trash)
    }

    private func verdicts(_ report: SecretaryPendingMarks.Report) -> [String: SecretaryPendingMarks.Verdict] {
        Dictionary(uniqueKeysWithValues: report.rows.map { ($0.file, $0.verdict) })
    }

    func testDryRunClassifiesEveryPendingMarkAndWritesNothing() throws {
        let before = try Data(contentsOf: store.directory.appendingPathComponent("marks.json"))
        let report = try audit(apply: false)
        XCTAssertEqual(report.pending, 7)
        XCTAssertEqual(verdicts(report), [
            "live.m4a": .queued, "cited.m4a": .citedWhilePending, "ahead.m4a": .markBehindRegistry,
            "binned.m4a": .closable, "loose.m4a": .closable, "renamed.m4a": .awaitingReconcile, "gone.m4a": .missingUnproven,
        ])
        XCTAssertEqual(report.rows.first { $0.file == "renamed.m4a" }?.presence, .trash, "the trash marker names the original file")
        XCTAssertFalse(report.rows.first { $0.file == "gone.m4a" }!.cited, "a reference definition alone is no citation")
        XCTAssertTrue(report.cleared.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("marks.json")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("secretary/runs/\(report.runID)").path))
    }

    func testApplyClearsOnlyProvenDeletionsAndBacksUpMarks() throws {
        let report = try audit(apply: true)
        XCTAssertEqual(report.cleared, ["binned.m4a", "loose.m4a"])
        XCTAssertTrue(report.findings.isEmpty)
        let marks = store.marks()
        XCTAssertNil(marks["binned.m4a"]); XCTAssertNil(marks["loose.m4a"])
        for file in ["live.m4a", "cited.m4a", "ahead.m4a", "renamed.m4a", "gone.m4a"] {
            XCTAssertEqual(marks[file]?.status, .pending, "\(file) stays pending")
        }
        XCTAssertEqual(marks["done.m4a"]?.status, .applied)
        let backup = try XCTUnwrap(report.backup)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(backup))) as! [String: Any]
        XCTAssertNotNil((saved["marks"] as? [String: Any])?["binned.m4a"], "the backup holds the marks before clearing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("secretary/runs/.lock").path))

        let again = try audit(apply: true)
        XCTAssertTrue(again.cleared.isEmpty)
        XCTAssertNil(again.backup, "nothing to close: no backup, no write")
    }

    func testClearLeavesAMarkThatChangedSinceItWasRead() throws {
        let read = store.marks()["binned.m4a"]!
        try store.update(["binned.m4a": mark("S4", .noise)])
        XCTAssertEqual(try store.clear(ifUnchanged: ["binned.m4a": read]), [])
        XCTAssertEqual(store.marks()["binned.m4a"]?.status, .noise)
    }

    func testPresenceTellsLibraryTrashAndMissingApart() {
        let found = MarkedNotePresence.locate(["live.m4a", "binned.m4a", "renamed.m4a", "gone.m4a"], active: library, trash: trash)
        XCTAssertEqual(found, ["live.m4a": .library, "binned.m4a": .trash, "renamed.m4a": .trash, "gone.m4a": .missing])
    }
}
