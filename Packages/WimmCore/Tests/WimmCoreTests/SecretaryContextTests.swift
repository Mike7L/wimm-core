import Foundation
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryContextTests: XCTestCase {
    private var root: URL!
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registry: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secretary-context-\(UUID().uuidString)")
        for folder in ["docs", "secretary/protocol", "run"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "# Intro\nprivate body\n```md\n## code example\n```\n## Real topic\n".write(to: document, atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ sources: [[String: Any]]) throws {
        var counts: [String: Int] = [:]
        for source in sources { counts[source["status"] as! String, default: 0] += 1 }
        try JSONSerialization.data(withJSONObject: ["sources": sources, "source_count": sources.count, "counts": counts]).write(to: registry)
    }
    private func source(_ number: Int) -> [String: Any] {
        ["source_id": "S\(number)", "path": "../recordings/note-\(number).meta.json", "status": "applied", "reason": "reason \(number)"]
    }
    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testSummaryNeverDumpsTheRegistryAndUsesNumericMaximum() throws {
        var high = source(50); high["source_id"] = "S00050"
        try write([source(9), high])
        let result = try decode(SecretaryContext.registry(document: document))
        XCTAssertEqual(result["next_source_id"] as? String, "S51")
        XCTAssertEqual(result["source_count"] as? Int, 2)
        XCTAssertEqual((result["sources"] as? [[String: Any]])?.count, 0)
    }
    func testExactFileSelectionKeepsLeadingSpacesAndPreservesUnknownFields() throws {
        var plain = source(1), spaced = source(2)
        plain["path"] = "../recordings/note.meta.json"
        spaced["path"] = "../recordings/%20note.meta.json"
        spaced["triage"] = "not part of the small projection"
        try write([plain, spaced]); let before = try Data(contentsOf: registry)
        let result = try decode(SecretaryContext.registry(document: document, references: [" note.txt"]))
        let rows = try XCTUnwrap(result["sources"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["source_id"] as? String, "S2")
        XCTAssertNil(rows.first?["triage"])
        XCTAssertEqual(try Data(contentsOf: registry), before)
    }
    func testSelectionIsPagedAndClippingIsExplicit() throws {
        var records = (1...35).map(source)
        records[0]["reason"] = String(repeating: "x", count: 5000)
        try write(records)
        let first = try decode(SecretaryContext.registry(document: document, query: "applied", limit: 500))
        XCTAssertEqual(first["matched"] as? Int, 35)
        XCTAssertEqual(first["next_offset"] as? Int, 20)
        let rows = try XCTUnwrap(first["sources"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual((rows.first?["reason"] as? String)?.count, 1200)
        XCTAssertEqual(rows.first?["truncated_fields"] as? [String], ["reason"])
        let next = try decode(SecretaryContext.registry(document: document, query: "applied", offset: 20))
        XCTAssertEqual((next["sources"] as? [[String: Any]])?.count, 15)
        XCTAssertNil(next["next_offset"])
    }
    func testAttachmentNamesResolveThroughTheExistingSidecarNamingRule() throws {
        var row = source(1); row["path"] = "../recordings/note.meta.json"
        try write([row])
        let result = try decode(SecretaryContext.registry(document: document, references: ["note_Attach_0.heic"]))
        XCTAssertEqual(result["matched"] as? Int, 1)
    }
    func testDocumentOutlineHasABoundedSizeAndReportsOmissions() throws {
        try write([source(1)])
        try (1...205).map { "## Topic \($0)" }.joined(separator: "\n").write(to: document, atomically: true, encoding: .utf8)
        let task = SecretaryTask(id: "context", kind: .pass, workspace: SecretaryWorkspace(document: document)!, threads: [], wimmCLI: "/cli", createdAt: Date())
        try SecretaryContext.write(task: task, directory: root.appendingPathComponent("run"))
        let context = try decode(Data(contentsOf: root.appendingPathComponent("run/context.json")))
        let outline = try String(contentsOf: root.appendingPathComponent("run/document-outline.txt"), encoding: .utf8)
        XCTAssertEqual(outline.split(separator: "\n").count, 201)
        XCTAssertTrue(outline.hasPrefix("headings: total=205, shown=200, truncated=true"))
        XCTAssertNotNil(context["registry"])
        XCTAssertLessThan(try Data(contentsOf: root.appendingPathComponent("run/context.json")).count, 3000)
    }

    func testInvalidOrDuplicateRegistryFailsBeforeProvidingNextID() throws {
        try write([source(1), source(1)])
        XCTAssertThrowsError(try SecretaryContext.registry(document: document))
        try Data(#"{"sources":[],"source_count":1,"counts":{}}"#.utf8).write(to: registry)
        XCTAssertThrowsError(try SecretaryContext.registry(document: document))
    }
    func testPreparedContextHasRealLineNumbersButNoBodyOrCodeHeadings() throws {
        try write([source(1)])
        let task = SecretaryTask(id: "context", kind: .pass, workspace: SecretaryWorkspace(document: document)!, threads: [], wimmCLI: "/cli", createdAt: Date())
        let directory = root.appendingPathComponent("run")
        try SecretaryContext.write(task: task, directory: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("context.json"))
        let context = try decode(data)
        let outline = try String(contentsOf: directory.appendingPathComponent("document-outline.txt"), encoding: .utf8)
        XCTAssertTrue(outline.contains("1 # Intro\n6 ## Real topic"))
        XCTAssertFalse(outline.contains("code example"))
        XCTAssertFalse(outline.contains("private body"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private body"))
        XCTAssertNotNil(context["document_outline"])
    }
    func testManagedProtocolSelectionDoesNotRequestFullProtocolOrSkill() throws {
        try "# Compact rules".write(to: root.appendingPathComponent("secretary/protocol/managed.md"), atomically: true, encoding: .utf8)
        let workspace = try XCTUnwrap(SecretaryWorkspace(document: document))
        let task = SecretaryTask(id: "context", kind: .pass, workspace: workspace, threads: [], wimmCLI: "/cli", createdAt: Date())
        let prompt = task.markdown()
        XCTAssertTrue(prompt.contains("`secretary/protocol/managed.md`"))
        XCTAssertTrue(prompt.contains("/cli secretary registry"))
        XCTAssertFalse(prompt.contains("`.claude/skills/secretary-pass/SKILL.md`"))
        XCTAssertFalse(prompt.contains("`secretary/protocol/registry.md`"))
        XCTAssertTrue(prompt.contains("reviewed_sources"))
    }
    func testCommentsContextDoesNotRequireARegistry() throws {
        let task = SecretaryTask(id: "context", kind: .comments, workspace: SecretaryWorkspace(document: document)!, threads: [], wimmCLI: "/cli", createdAt: Date())
        try SecretaryContext.write(task: task, directory: root.appendingPathComponent("run"))
        let context = try decode(Data(contentsOf: root.appendingPathComponent("run/context.json")))
        XCTAssertNil(context["registry"])
    }

    func testProtocolVersionIsCapturedAndOldManagedWorkspacesKeepTheirContract() throws {
        let folder = root.appendingPathComponent("secretary/protocol")
        try "# v1".write(to: folder.appendingPathComponent("managed.md"), atomically: true, encoding: .utf8)
        let workspace = SecretaryWorkspace(document: document)!
        let old = SecretaryTask(id: "old", kind: .pass, workspace: workspace, threads: [], wimmCLI: "/cli", createdAt: Date())
        try "# v2".write(to: folder.appendingPathComponent("managed-review.md"), atomically: true, encoding: .utf8)
        let modern = SecretaryTask(id: "new", kind: .pass, workspace: workspace, threads: [], wimmCLI: "/cli", createdAt: Date())
        XCTAssertFalse(old.usesSourceDecisions)
        XCTAssertEqual(old.protocolPath, "secretary/protocol/managed.md")
        XCTAssertTrue(modern.usesSourceDecisions)
        XCTAssertTrue(modern.markdown().contains("`secretary/protocol/managed-review.md`"))
        XCTAssertTrue(modern.markdown().contains("Существующие записи реестра не редактировать"))
        XCTAssertTrue(old.markdown().contains("Старые записи править адресно"))
    }

}
