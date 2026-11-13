import Foundation
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryCompletionTests: XCTestCase {
    private var root: URL!
    private var document: URL!
    private var backup: URL!
    private var marks: AgentMarkStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        document = root.appendingPathComponent("docs/me.md")
        backup = root.appendingPathComponent("before.md")
        try Data("# Topic\n\nOriginal.\n".utf8).write(to: document)
        try Data(contentsOf: document).write(to: backup)
        marks = AgentMarkStore(directory: root.appendingPathComponent("state"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func task(_ kind: SecretaryRunKind = .comments) throws -> SecretaryTask {
        SecretaryTask(id: "test", kind: kind, workspace: try XCTUnwrap(SecretaryWorkspace(document: document)), threads: [], wimmCLI: "/cli", createdAt: Date())
    }
    private var log: URL { SecretaryReadReceipt.logURL(runID: "test", store: marks) }
    private var context: SecretaryCompletion.ReviewContext {
        .init(document: document, backup: backup, log: log.appendingPathExtension("review"))
    }
    private func findings(_ kind: SecretaryRunKind = .comments) throws -> [String] {
        SecretaryCompletion.findings(task: try task(kind), backup: backup, store: marks)
    }

    func testUnchangedDocumentNeedsNoReviewButPassStillNeedsQueueCheck() throws {
        XCTAssertEqual(try findings(), [])
        XCTAssertTrue(try findings(.pass).contains { $0.contains("queue coverage is unknown") })
    }

    func testEveryFinalPageRequiredAndLaterEditInvalidatesReceipts() throws {
        try Data(("# Topic\n" + String(repeating: "A long changed paragraph. ", count: 900)).utf8).write(to: document)
        XCTAssertFalse(try findings().isEmpty)
        let pages = SecretaryCompletion.pages(before: try Data(contentsOf: backup), after: try Data(contentsOf: document))
        XCTAssertGreaterThan(pages.count, 1)
        _ = try SecretaryCompletion.review(context, page: 0)
        XCTAssertFalse(try findings().isEmpty, "one page cannot acknowledge the whole rewrite")
        for page in 1..<pages.count { _ = try SecretaryCompletion.review(context, page: page) }
        XCTAssertEqual(try findings(), [])
        try Data("# Topic\nA subsequent edit.\n".utf8).write(to: document)
        XCTAssertFalse(try findings().isEmpty)
        _ = try SecretaryCompletion.review(context, page: 0)
        XCTAssertEqual(try findings(), [])
    }

    func testDeletionShowsRemovedTextAndSurvivingJoin() throws {
        let before = Data("First.\nDELETE THIS\nLast.\n".utf8), after = Data("First.\nLast.\n".utf8)
        let output = SecretaryCompletion.pages(before: before, after: after).joined()
        XCTAssertTrue(output.contains("BEFORE L2 * DELETE THIS"))
        XCTAssertTrue(output.contains("AFTER L2 * Last."))
        XCTAssertFalse(output.contains("AFTER L2 * DELETE THIS"))
    }

    func testInvalidPageAndPrivateModeCannotCreateReviewEvidence() async throws {
        try Data("Changed".utf8).write(to: document)
        XCTAssertThrowsError(try SecretaryCompletion.review(context, page: -1))
        XCTAssertThrowsError(try SecretaryCompletion.review(context, page: 100))
        let config = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let server = MCPRecallServer(isPrivate: { true }, reviewConfiguration: config, library: { RecallLibrary([]) })
        let response = await server.callTool(name: "secretary_review_document", arguments: ["page": 0])
        XCTAssertEqual(response["isError"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.log.path))
    }

    func testMCPReviewWritesCoverageForSuppliedFinalText() async throws {
        try Data("Updated".utf8).write(to: document)
        let config = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let server = MCPRecallServer(isPrivate: { false }, reviewConfiguration: config, library: { RecallLibrary([]) })
        let response = await server.callTool(name: "secretary_review_document", arguments: ["page": 0])
        XCTAssertNotEqual(response["isError"] as? Bool, true)
        XCTAssertTrue(String(describing: response).contains("Updated"))
        XCTAssertEqual(try findings(), [])
    }

    func testSuccessfulQueueCallRecordsPolicyEmptyQueueAndRejectsWrongPolicy() async throws {
        try marks.setPass(.init(asOf: Date(timeIntervalSince1970: 0), cursor: nil, comment: nil, setAt: Date()))
        let server = MCPRecallServer(isPrivate: { false }, marks: marks, readLog: log, library: { RecallLibrary([]) })
        _ = await server.callTool(name: "changed_notes", arguments: [:])
        XCTAssertFalse(try findings(.pass).isEmpty)
        let response = await server.callTool(name: "changed_notes", arguments: ["since": "last_pass", "skip_unchanged_marked": true,
            "marked_changes": "transcript,edited", "order": "newest_first", "limit": 20])
        XCTAssertNotEqual(response["isError"] as? Bool, true)
        XCTAssertEqual(try findings(.pass), [])
        let receipts = try SecretaryCompletion.read(SecretaryCompletion.QueueReceipt.self, at: log.appendingPathExtension("queue"))
        XCTAssertEqual(receipts.last?.remaining, 0)
        XCTAssertEqual(receipts.last?.returned, 0)
    }

    func testCommentsCannotAcknowledgeTruncatedSourceButFullRereadRepairsCoverage() throws {
        var receipt = SecretaryReadReceipt(file: "/fixture/note.txt", sidecar: "/fixture/note.meta.json", noteID: "note",
            sha256: "hash", text: "text", analysis: "analysis", suppliedText: [.init(block: 0, label: "body", transcriptKind: nil, state: "truncated")])
        try receipt.append(to: log)
        XCTAssertTrue(try findings().contains { $0.contains("incomplete source coverage") })
        receipt.suppliedText = [.init(block: 0, label: "body", transcriptKind: nil, state: "full")]
        try receipt.append(to: log)
        XCTAssertEqual(try findings(), [])
    }

    func testFailedQueueCallCannotAcknowledgeScan() async throws {
        let server = MCPRecallServer(isPrivate: { true }, marks: marks, readLog: log, library: { RecallLibrary([]) })
        _ = await server.callTool(name: "changed_notes", arguments: ["since": "last_pass", "skip_unchanged_marked": true,
            "marked_changes": "transcript,edited", "order": "newest_first"])
        XCTAssertFalse(try findings(.pass).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.appendingPathExtension("queue").path))
    }
}
