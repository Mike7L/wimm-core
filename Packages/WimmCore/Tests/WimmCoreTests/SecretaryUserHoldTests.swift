import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

/// `wimm-cli secretary hold`: Wimm sets explicit user holds on existing registry
/// rows; preparation then reports the source as held and never reads it.
final class SecretaryUserHoldTests: XCTestCase {
    private var root: URL!
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registry: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }
    private var media: URL { root.appendingPathComponent("recordings/lost.txt") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hold-test-\(UUID().uuidString)")
        for name in ["recordings", "docs", "secretary/protocol", "secretary/runs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // What lost-to-text leaves: an old sidecar, now beside a new .txt.
        try "[Расшифровка утраченной аудиозаписи · 1 мин · записано 2026-01-14 09:12]\n\nтекст".write(to: media, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: media)) { $0["recordingId"] = "lost"; return true }
        try "# Документ\n\nТекст.\n".write(to: document, atomically: true, encoding: .utf8)
        try "# Источники".write(to: root.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\nНет.\n".write(to: root.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        try writeRegistry([
            ["source_id": "S1", "path": "../recordings/lost.meta.json", "note_file": "lost.m4a", "status": "pending",
             "reason": "old", "wimm_unindexed": "2026-10-25: no media"],
            ["source_id": "S2", "path": "../recordings/other.meta.json", "note_file": "other.txt", "status": "applied", "reason": "kept"],
        ])
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func writeRegistry(_ sources: [[String: Any]]) throws {
        var counts: [String: Int] = [:]
        for source in sources { counts[source["status"] as! String, default: 0] += 1 }
        try JSONSerialization.data(withJSONObject: ["sources": sources, "source_count": sources.count, "counts": counts,
                                                    "batches": [["original": true]]], options: [.prettyPrinted, .sortedKeys]).write(to: registry)
    }

    private func rows() throws -> [String: [String: Any]] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [String: Any]
        return Dictionary(uniqueKeysWithValues: (root["sources"] as! [[String: Any]]).map { ($0["source_id"] as! String, $0) })
    }

    func testDryRunChangesNothingAndApplyHoldsTheExactFile() throws {
        let before = try Data(contentsOf: registry)
        let dry = try SecretaryUserHold.hold(document: document, files: ["lost.txt", "missing.txt"], reason: "user said hold", apply: false)
        XCTAssertEqual(dry.held, ["S1": "lost.txt"])
        XCTAssertEqual(dry.notInRegistry, ["missing.txt"])
        XCTAssertEqual(try Data(contentsOf: registry), before, "a dry run writes nothing")

        let applied = try SecretaryUserHold.hold(document: document, files: ["lost.txt"], reason: "user said hold", apply: true)
        XCTAssertEqual(applied.held, ["S1": "lost.txt"])
        let row = try rows()["S1"]!
        let hold = row["user_exclusion"] as! [String: Any]
        XCTAssertEqual(hold["active"] as? Bool, true)
        XCTAssertEqual(hold["authority"] as? String, "user")
        XCTAssertEqual(hold["scope"] as? String, "source")
        XCTAssertEqual(hold["resume"] as? String, "explicit_user_release")
        XCTAssertEqual(hold["reason"] as? String, "user said hold")
        XCTAssertEqual(row["note_file"] as? String, "lost.txt")
        XCTAssertEqual((row["media_file_history"] as? [[String: Any]])?.first?["previous_file"] as? String, "lost.m4a")
        XCTAssertEqual(row["status"] as? String, "pending", "status untouched")
        XCTAssertEqual(row["wimm_unindexed"] as? String, "2026-10-25: no media", "other flags untouched")
        XCTAssertEqual(try rows()["S2"]!["reason"] as? String, "kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(applied.registryBackup!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("secretary/runs/.lock").path))

        let again = try SecretaryUserHold.hold(document: document, files: ["lost.txt"], reason: "user said hold", apply: true)
        XCTAssertEqual(again.alreadyHeld, ["S1"])
        XCTAssertTrue(again.held.isEmpty)
    }

    /// The hold is the one preparation honours: the note is listed as held, never read.
    func testPreparationReportsTheHeldNoteAndReadsNothing() throws {
        // Clear the old flag so only the hold can keep the note out.
        try writeRegistry([["source_id": "S1", "path": "../recordings/lost.meta.json", "note_file": "lost.m4a",
                            "status": "pending", "reason": "old"]])
        _ = try SecretaryUserHold.hold(document: document, files: ["lost.txt"], reason: "user said hold", apply: true)
        let task = SecretaryTask(id: "hold-prepare", kind: .pass, workspace: SecretaryWorkspace(document: document)!,
                                 threads: [], wimmCLI: "/usr/bin/true", createdAt: Date(), packetMode: true)
        let library = RecallLibrary([RecallNote(id: "lost", date: Date(), kind: "text", title: nil, summary: nil,
                                                text: "x", filePath: media.path, updated: Date())])
        let store = AgentMarkStore(directory: root.appendingPathComponent("state"))
        XCTAssertThrowsError(try SecretaryPacket.prepare(task: task, library: library, marks: store)) {
            XCTAssertTrue($0.localizedDescription.contains("explicitly held"), $0.localizedDescription)
        }
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testTwoRowsForOneSidecarAreNotGuessed() throws {
        try writeRegistry([
            ["source_id": "S1", "path": "../recordings/lost.meta.json", "note_file": "lost.m4a", "status": "pending"],
            ["source_id": "S3", "path": "../recordings/lost.meta.json", "note_file": "lost_Attach_1.jpg", "status": "pending"],
        ])
        let before = try Data(contentsOf: registry)
        let report = try SecretaryUserHold.hold(document: document, files: ["lost.txt"], reason: "r", apply: true)
        XCTAssertEqual(report.ambiguous, ["lost.txt"])
        XCTAssertEqual(try Data(contentsOf: registry), before)
    }

    func testUndoRestoresTheExactRowAndLeavesChangedRowsAlone() throws {
        let before = try rows()["S1"]!
        let held = try SecretaryUserHold.hold(document: document, files: ["lost.txt"], reason: "r", apply: true)
        XCTAssertEqual(try SecretaryUserHold.heldFiles(document: document, runID: held.runID), ["lost.txt"])

        let dry = try SecretaryUserHold.undo(document: document, runID: held.runID, files: ["lost.txt", "other.txt"], apply: false)
        XCTAssertEqual(dry.held, ["S1": "lost.txt"])
        XCTAssertEqual(dry.notInRegistry, ["other.txt"], "S2 was not held by that run")

        let undone = try SecretaryUserHold.undo(document: document, runID: held.runID, files: ["lost.txt"], apply: true)
        XCTAssertEqual(undone.held, ["S1": "lost.txt"])
        XCTAssertTrue(SecretaryRegistryRevision.equal(try rows()["S1"]!, before), "row is back to its pre-hold copy")

        // Held again, then edited by someone: undo refuses that row.
        let again = try SecretaryUserHold.hold(document: document, files: ["lost.txt"], reason: "r", apply: true)
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as! [String: Any]
        var sources = root["sources"] as! [[String: Any]]
        sources[0]["status"] = "applied"; root["sources"] = sources
        try JSONSerialization.data(withJSONObject: root).write(to: registry)
        let refused = try SecretaryUserHold.undo(document: document, runID: again.runID, files: ["lost.txt"], apply: true)
        XCTAssertEqual(refused.ambiguous, ["lost.txt"])
        XCTAssertEqual(try rows()["S1"]!["status"] as? String, "applied")
    }
}
