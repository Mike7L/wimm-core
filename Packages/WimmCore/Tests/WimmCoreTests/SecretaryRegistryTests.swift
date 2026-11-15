import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

/// The registry lives in the workspace, which the outside agent may edit: a malformed
/// row or a duplicate `source_id` must be a thrown error naming the row, never a crash.
final class SecretaryRegistryTests: XCTestCase {
    private var root: URL!
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var registryURL: URL { SecretaryRegistry.url(document: document) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-test-\(UUID().uuidString)")
        for name in ["docs", "recordings", "secretary/runs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "# Документ\n\nФакт [S1].\n".write(to: document, atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func row(_ id: Any = "S1", status: Any = "applied", path: Any = "../recordings/a.meta.json") -> [String: Any] {
        ["source_id": id, "status": status, "path": path, "note_file": "a.txt"]
    }
    private func data(_ sources: Any, counts: [String: Int]? = nil) throws -> Data {
        var root: [String: Any] = ["sources": sources]
        if let rows = sources as? [[String: Any]] {
            root["source_count"] = rows.count
            root["counts"] = counts ?? Dictionary(rows.compactMap { $0["status"] as? String }.map { ($0, 1) }, uniquingKeysWith: +)
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    private func assertRejected(_ data: Data, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SecretaryRegistry.parse(data), file: file, line: line) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("registry:"), message, file: file, line: line)
            XCTAssertTrue(message.contains(expected), "\(message) lacks \(expected)", file: file, line: line)
        }
    }

    func testValidRegistryKeepsRowsAndUnknownFields() throws {
        var second = row("S12", status: "duplicate", path: "../recordings/b.meta.json")
        second["triage"] = ["kept": true]
        let registry = try SecretaryRegistry.parse(data([row(), second]))
        XCTAssertEqual(registry.rows.count, 2)
        XCTAssertEqual(registry.maxNumber, 12)
        XCTAssertEqual(registry.counts, ["applied": 1, "duplicate": 1])
        XCTAssertEqual((registry.byID["S12"]?["triage"] as? [String: Bool]), ["kept": true])
        XCTAssertNoThrow(try registry.checkCounts())
    }

    func testMissingFieldsAreNamed() throws {
        var noID = row(); noID.removeValue(forKey: "source_id")
        assertRejected(try data([row(), noID]), "sources[1]: missing source_id")
        var noStatus = row(); noStatus.removeValue(forKey: "status")
        assertRejected(try data([noStatus]), "sources[0] (S1): missing status")
        var noPath = row(); noPath.removeValue(forKey: "path")
        assertRejected(try data([noPath]), "sources[0] (S1): missing path")
        assertRejected(try JSONSerialization.data(withJSONObject: ["counts": [:]]), "no sources array")
    }

    func testWrongTypesAreNamed() throws {
        assertRejected(try data([row(7)]), "sources[0]: source_id is not a string")
        assertRejected(try data([row(status: 1)]), "sources[0] (S1): status is not a string")
        assertRejected(try data([row(path: NSNull())]), "sources[0] (S1): path is not a string")
        assertRejected(try data([row(), "S2"]), "sources[1] is not an object")
        assertRejected(try data(["S1": row()]), "sources is not an array")
        assertRejected(try data([row("note-1")]), "source_id \"note-1\" is not S<number>")
        assertRejected(Data("[]".utf8), "top level is not an object")
        assertRejected(Data("{".utf8), "not valid JSON")
    }

    func testUnknownStatusIsNamed() throws {
        assertRejected(try data([row(status: "maybe")]), "sources[0] (S1): unknown status \"maybe\"")
    }

    func testDuplicateSourceIDIsNamed() throws {
        assertRejected(try data([row(), row("S2"), row()]), "sources[2]: duplicate source_id S1")
        XCTAssertThrowsError(try SecretaryRegistry.parse(data([row()])).indexed(adding: [row()])) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate source_id S1"), error.localizedDescription)
        }
    }

    // MARK: Entry points fail closed instead of crashing.

    private var task: SecretaryTask {
        SecretaryTask(id: "registry-test", kind: .pass, workspace: SecretaryWorkspace(document: document)!,
                      threads: [], wimmCLI: "/usr/bin/true", createdAt: Date())
    }

    func testContextSummaryThrowsOnDuplicate() throws {
        try data([row(), row()]).write(to: registryURL)
        XCTAssertThrowsError(try SecretaryContext.registry(document: document)) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate source_id S1"), error.localizedDescription)
        }
    }

    func testBookkeepingReportsMalformedRegistryAsFinding() async throws {
        for bad in [try data([row(), row()]), try data([row(status: "maybe")]), try data([row(status: 3)])] {
            try bad.write(to: registryURL)
            let report = await SecretaryBookkeeping.finish(task: task, result: SecretaryResult(reviewedSources: ["S1"]),
                store: AgentMarkStore(directory: root.appendingPathComponent("state")), recordings: { [] })
            XCTAssertEqual(report.stored, 0)
            XCTAssertTrue(report.findings.contains { $0.hasPrefix("registry:") }, "\(report.findings)")
            XCTAssertEqual(try Data(contentsOf: registryURL), bad, "a rejected registry is never rewritten")
        }
    }

    func testUserHoldThrowsOnMalformedRegistry() throws {
        var noID = row(); noID.removeValue(forKey: "source_id")
        for bad in [try data([row(), row()]), try data([noID])] {
            try bad.write(to: registryURL)
            XCTAssertThrowsError(try SecretaryUserHold.hold(document: document, files: ["a.txt"], reason: "user said so", apply: true)) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("registry:"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: registryURL), bad)
        }
    }

    func testAddingSourcesAndCitationRepairThrowOnDuplicate() throws {
        XCTAssertThrowsError(try SecretaryPacket.addingSources([row("S2")], data: data([row(), row()])))
        XCTAssertThrowsError(try SecretaryCitationDefinitions.repair(document: Data("x [S1]\n".utf8), sources: [row(), row()]))
        // Valid input still patches as before.
        let added = try SecretaryPacket.addingSources([row("S2", status: "pending")], data: data([row()]))
        let parsed = try SecretaryRegistry.parse(added)
        XCTAssertEqual(parsed.rows.map { $0["source_id"] as? String }, ["S1", "S2"])
        XCTAssertNoThrow(try parsed.checkCounts())
    }
}
