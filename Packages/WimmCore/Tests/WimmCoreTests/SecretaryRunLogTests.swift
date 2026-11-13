import Foundation
import XCTest
@testable import WimmSecretary

final class SecretaryRunLogTests: XCTestCase {
    private var root: URL!
    private var workspace: SecretaryWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary/runs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let doc = root.appendingPathComponent("docs/me.md")
        try Data("# T\n".utf8).write(to: doc)
        workspace = try XCTUnwrap(SecretaryWorkspace(document: doc))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeRun(_ id: String, outcome: SecretaryRunRecord.Outcome?, workflow: String = "packet",
                         findings: [String] = [], error: String? = nil, execution: SecretaryExecution? = nil,
                         task: Bool = true) throws {
        let dir = workspace.runDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = SecretaryRunRecord(id: id, kind: .pass, doc: "docs/me.md", executor: "claude-code", model: "haiku",
                                        workflow: workflow, threadIDs: [], startedAt: "2026-11-04T10:00:00Z", finishedAt: nil)
        record.outcome = outcome; record.findings = findings; record.error = error
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent("run.json"))
        if task { try Data("task".utf8).write(to: dir.appendingPathComponent("task.md")) }
        if let execution { try JSONEncoder().encode(execution).write(to: dir.appendingPathComponent("packet-execution.json")) }
    }

    func testRunIDsIgnoreOtherFoldersAndSortOldestFirst() throws {
        try makeRun("20261104-100000-abcd", outcome: .succeeded, execution: .init(exitStatus: 0, finalText: "x", costUSD: 0.01))
        try makeRun("20261103-090000-1234", outcome: .succeeded, execution: .init(exitStatus: 0, finalText: "x", costUSD: 0.01))
        try FileManager.default.createDirectory(at: workspace.runDirectory("scratch"), withIntermediateDirectories: true)
        XCTAssertEqual(SecretaryRunLog.runIDs(in: workspace), ["20261103-090000-1234", "20261104-100000-abcd"])
    }

    func testCleanPacketRunHasNoProblems() throws {
        let id = "20261104-100000-abcd"
        try makeRun(id, outcome: .succeeded, execution: .init(exitStatus: 0, finalText: "done", costUSD: 0.02, tokensIn: 10, tokensOut: 5))
        let entry = SecretaryRunLog.entry(id: id, in: workspace)
        XCTAssertEqual(entry.problems, [])
        XCTAssertTrue(SecretaryRunLog.summaryLine(entry).contains("succeeded"))
        XCTAssertTrue(SecretaryRunLog.report(entry).contains("run.json"))
    }

    func testFilePacketUsesExportManifestInsteadOfAgentTask() throws {
        let id = "20261104-100007-abcd"
        try makeRun(id, outcome: .succeeded, workflow: "file-packet", task: false)
        XCTAssertEqual(SecretaryRunLog.entry(id: id, in: workspace).problems, ["file-packet manifest missing"])
        let export = workspace.runDirectory(id).appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: export.appendingPathComponent("manifest.json"))
        XCTAssertTrue(SecretaryRunLog.entry(id: id, in: workspace).problems.isEmpty)
    }

    func testBrokenRunsAreReportedNotThrown() throws {
        let missing = "20261104-100001-aaaa"
        try FileManager.default.createDirectory(at: workspace.runDirectory(missing), withIntermediateDirectories: true)
        XCTAssertTrue(SecretaryRunLog.entry(id: missing, in: workspace).problems.contains("run.json missing"))

        let unfinished = "20261104-100002-bbbb"
        try makeRun(unfinished, outcome: nil, execution: .init(exitStatus: 0, finalText: "x", costUSD: 0))
        XCTAssertTrue(SecretaryRunLog.entry(id: unfinished, in: workspace).problems.contains { $0.contains("never finished") })

        let noText = "20261104-100003-cccc"
        try makeRun(noText, outcome: .succeeded, execution: .init(exitStatus: 0, finalText: nil))
        let problems = SecretaryRunLog.entry(id: noText, in: workspace).problems
        XCTAssertTrue(problems.contains { $0.contains("no final text") })
        XCTAssertTrue(problems.contains { $0.contains("usage unknown") })

        let noPacket = "20261104-100004-dddd"
        try makeRun(noPacket, outcome: .succeeded)
        XCTAssertTrue(SecretaryRunLog.entry(id: noPacket, in: workspace).problems.contains { $0.contains("without packet-execution.json") })
    }

    func testSucceededWithFindingsAndSilentFailureAreProblems() throws {
        let a = "20261104-100005-eeee", b = "20261104-100006-ffff"
        try makeRun(a, outcome: .succeeded, workflow: "agent", findings: ["registry mismatch"])
        try makeRun(b, outcome: .failed, workflow: "agent")
        XCTAssertTrue(SecretaryRunLog.entry(id: a, in: workspace).problems.contains { $0.contains("finding") })
        XCTAssertTrue(SecretaryRunLog.entry(id: b, in: workspace).problems.contains { $0.contains("without error or finding") })
    }
}
