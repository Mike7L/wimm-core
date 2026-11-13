import Foundation
import XCTest
@testable import WimmSecretary

/// The secretary window's read side: run history, format switch, effort preference.
final class SecretaryRunHistoryTests: XCTestCase {
    private var root: URL!
    private var workspace: SecretaryWorkspace { SecretaryWorkspace(document: root.appendingPathComponent("docs/me.md"))! }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("run-history-\(UUID().uuidString)")
        for name in ["docs", "secretary/protocol", "secretary/runs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "# Документ\n".write(to: root.appendingPathComponent("docs/me.md"), atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func run(_ id: String, cost: Double, report: SecretaryPacket.EditsReport? = nil) throws {
        let directory = workspace.runDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var record = SecretaryRunRecord(id: id, kind: .pass, doc: "me", executor: "claude", threadIDs: [], startedAt: "2026-10-31T20:00:00Z")
        record.outcome = .succeeded; record.costUSD = cost
        record.hostQueues = SecretaryHostQueues(waitingForText: 3, waitingForViewing: 1, skipped: 2, unfinished: 4)
        try SecretaryDispatcher.write(record, to: directory)
        if let report {
            try JSONEncoder().encode(report).write(to: directory.appendingPathComponent(SecretaryPacket.editsReportName))
        }
    }

    private func source(_ id: String, _ outcome: String, _ reason: String? = nil) -> SecretaryPacket.SourceOutcome {
        SecretaryPacket.SourceOutcome(id: id, file: "\(id).txt", sha256: "x", text: "t", analysis: "a", outcome: outcome, reason: reason)
    }

    func testRecentListsRunsNewestFirstAndSkipsNonRuns() throws {
        try run("20261031-190000-aaaa", cost: 0.1)
        try run("20261031-200000-bbbb", cost: 0.3)
        try FileManager.default.createDirectory(at: workspace.runDirectory("context-sample-20261031"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.runDirectory("20261031-210000-cccc"), withIntermediateDirectories: true)

        let runs = SecretaryRunHistory.recent(workspace)
        XCTAssertEqual(runs.map(\.id), ["20261031-200000-bbbb", "20261031-190000-aaaa"])
        XCTAssertEqual(runs.first?.record?.costUSD, 0.3)
        XCTAssertEqual(runs.first?.record?.hostQueues?.unfinished, 4)
        XCTAssertNotNil(runs.first?.startedAt)
        XCTAssertEqual(SecretaryRunHistory.recent(workspace, limit: 1).count, 1)
    }

    func testFormatTwoReportIsSummarized() throws {
        let report = SecretaryPacket.EditsReport(
            format: 2, accepted: true, rejection: nil,
            edits: [.init(index: 0, operation: "replace_text", target: "b3", sources: ["S1"], deleted: "старый текст"),
                    .init(index: 1, operation: "insert_under_heading", target: "b5", sources: ["S2"], deleted: nil)],
            sources: [source("S1", "used"), source("S2", "used"), source("S3", "reviewed"),
                      source("S4", "unfinished", "нужен раздел"), source("S5", "unmentioned")],
            ignoredSources: [], lazyReply: false, summary: "Итог")
        try run("20261031-200000-bbbb", cost: 0.3, report: report)

        let edits = try XCTUnwrap(SecretaryRunHistory.recent(workspace).first?.edits)
        XCTAssertTrue(edits.accepted)
        XCTAssertEqual(edits.editCount, 2)
        XCTAssertEqual(edits.count("used"), 2)
        XCTAssertEqual(edits.count("reviewed"), 1)
        XCTAssertEqual(edits.count("unmentioned"), 1)
        XCTAssertEqual(edits.count("rejected"), 0)
        XCTAssertEqual(edits.unfinished, [.init(source: "S4", detail: "нужен раздел")])
        XCTAssertEqual(edits.deleted, [.init(source: "S1", detail: "старый текст")])
    }

    func testFormatSwitchParksAndRestoresTheProtocol() throws {
        XCTAssertFalse(SecretaryResponseFormatSetting.isAvailable(workspace))
        let policy = root.appendingPathComponent(SecretaryPacket.editsPolicyPath)
        try "Протокол правок.".write(to: policy, atomically: true, encoding: .utf8)
        XCTAssertEqual(SecretaryResponseFormatSetting.current(workspace), 2)
        XCTAssertTrue(SecretaryResponseFormatSetting.isAvailable(workspace))

        XCTAssertThrowsError(try SecretaryResponseFormatSetting.set(1, in: workspace)) { error in
            XCTAssertTrue(error.localizedDescription.contains("format 1 has been removed"))
        }

        try SecretaryResponseFormatSetting.set(2, in: workspace)
        XCTAssertEqual(SecretaryResponseFormatSetting.current(workspace), 2)
        XCTAssertEqual(try String(contentsOf: policy, encoding: .utf8), "Протокол правок.")
    }

    func testEffortPreferenceIgnoresUnknownValues() {
        let defaults = UserDefaults(suiteName: "effort-\(UUID().uuidString)")!
        XCTAssertEqual(SecretaryEffortSetting.preferred(defaults: defaults), "")
        SecretaryEffortSetting.store("high", defaults: defaults)
        XCTAssertEqual(SecretaryEffortSetting.preferred(defaults: defaults), "high")
        defaults.set("max", forKey: SecretaryEffortSetting.defaultsKey)
        XCTAssertEqual(SecretaryEffortSetting.preferred(defaults: defaults), "")
        SecretaryEffortSetting.store("", defaults: defaults)
        XCTAssertNil(defaults.string(forKey: SecretaryEffortSetting.defaultsKey))
    }
}
