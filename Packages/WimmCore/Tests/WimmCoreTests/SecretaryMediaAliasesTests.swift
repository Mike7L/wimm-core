import Foundation
import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryMediaAliasesTests: XCTestCase {
    func testOnlyUniquePendingOwnerCanRepairHiddenAliasWithoutAcknowledgingText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["docs", "recordings", "secretary"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let document = root.appendingPathComponent("docs/me.md")
        try Data("# Test".utf8).write(to: document)
        let file = root.appendingPathComponent("recordings/n.m4a")
        try Data("fixture".utf8).write(to: file)
        let sidecar = FileStore.metadataURL(forRecordingURL: file)
        try FileStore.mutateSidecar(at: sidecar) { $0["recordingId"] = "n"; return true }
        let before = try Data(contentsOf: sidecar)
        let task = SecretaryTask(id: "alias-test", kind: .pass, workspace: SecretaryWorkspace(document: document)!, threads: [], wimmCLI: "/unused", createdAt: Date())
        let row: [String: Any] = ["source_id": "S1", "status": "pending", "primary_text_read": false,
                                  "note_file": "n_Attach_Text.txt", "path": "../recordings/n.meta.json"]
        let mark = AgentMarkStore.Mark(status: .pending, source: "S1", markedAt: Date(), noteId: "n", text: "old", analysis: "old")
        func resolve(_ rows: [[String: Any]], _ marks: [String: AgentMarkStore.Mark], files: [URL] = []) -> [String: [String: Any]] {
            SecretaryLibraryReconciliation.mediaAliases(sources: rows, task: task, marks: marks, indexedFiles: files.isEmpty ? [file] : files)
        }
        let updated = try XCTUnwrap(resolve([row], [file.lastPathComponent: mark])["S1"])
        XCTAssertEqual(updated["note_file"] as? String, "n.m4a")
        XCTAssertEqual(updated["status"] as? String, "pending")
        XCTAssertEqual(updated["primary_text_read"] as? Bool, false)
        XCTAssertEqual((updated["media_file_history"] as? [[String: Any]])?.first?["previous_file"] as? String, "n_Attach_Text.txt")
        XCTAssertTrue(resolve([row.merging(["user_exclusion": ["active": true]]) { _, b in b }], ["n.m4a": mark]).isEmpty)
        var settled = mark; settled.status = .applied
        XCTAssertTrue(resolve([row], ["n.m4a": settled]).isEmpty)
        XCTAssertTrue(resolve([row], ["n.m4a": mark, "another.m4a": mark]).isEmpty)
        XCTAssertTrue(resolve([row, ["source_id": "S2", "note_file": "n.m4a"]], ["n.m4a": mark]).isEmpty)
        var missingFile = row; missingFile.removeValue(forKey: "note_file")
        let recovered = try XCTUnwrap(resolve([missingFile], ["n.m4a": mark])["S1"])
        XCTAssertEqual(recovered["note_file"] as? String, "n.m4a")
        XCTAssertEqual(recovered["primary_text_read"] as? Bool, false)
        XCTAssertTrue(resolve([row.merging(["path": "../recordings/other.meta.json"]) { _, b in b }], ["n.m4a": mark]).isEmpty)
        XCTAssertTrue(resolve([updated], ["n.m4a": mark]).isEmpty, "repair is idempotent")
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
    }
}
