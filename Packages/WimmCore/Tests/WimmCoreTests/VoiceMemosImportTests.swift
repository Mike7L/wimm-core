import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class VoiceMemosImportTests: XCTestCase {
    var root: URL!
    var source: URL!
    var dest: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-import-\(UUID().uuidString)")
        source = root.appendingPathComponent("VM")
        dest = root.appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func plan(_ items: [VoiceMemosImport.Item]) -> VoiceMemosImport.Plan {
        .init(sourceDir: source.path, items: items)
    }

    private func item(src: String = "a.m4a", dst: String = "Wimm_2023-01-14_01-59-49_1928D839.m4a",
                      ts: String = "2023-01-14T00:59:49Z", size: Int? = 5) -> VoiceMemosImport.Item {
        .init(src: src, dst: dst, timestamp: ts, dateSource: "CloudRecordings.db", size: size, label: nil, borderline: nil)
    }

    func testDryRunChangesNothing() throws {
        try Data("12345".utf8).write(to: source.appendingPathComponent("a.m4a"))
        let rows = VoiceMemosImport.run(plan: plan([item()]), destination: dest, apply: false)
        XCTAssertEqual(rows.first?.outcome, .wouldImport)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    func testApplyCopiesWritesSidecarAndDates() throws {
        try Data("12345".utf8).write(to: source.appendingPathComponent("a.m4a"))
        let rows = VoiceMemosImport.run(plan: plan([item()]), destination: dest, apply: true)
        XCTAssertEqual(rows.first?.outcome, .imported)
        let file = dest.appendingPathComponent("Wimm_2023-01-14_01-59-49_1928D839.m4a")
        XCTAssertEqual(try Data(contentsOf: file), Data("12345".utf8))
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: file))) as? [String: Any]
        XCTAssertEqual(meta?["timestamp"] as? String, "2023-01-14T00:59:49Z")
        XCTAssertNil(meta?["attachments"])
        XCTAssertNil(meta?["transcription"])
        XCTAssertEqual((meta?["voiceMemos"] as? [String: Any])?["file"] as? String, "a.m4a")
        let created = try FileStore.fileCreationDate(file)
        XCTAssertEqual(created.timeIntervalSince1970, 1673657989, accuracy: 1)
        // Source untouched, no leftovers.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.m4a").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dest.path).contains { $0.hasSuffix(".part") })
    }

    func testNeverOverwritesAndRejectsBadItems() throws {
        try Data("12345".utf8).write(to: source.appendingPathComponent("a.m4a"))
        try Data("old".utf8).write(to: dest.appendingPathComponent("Wimm_2023-01-14_01-59-49_1928D839.m4a"))
        var rows = VoiceMemosImport.run(plan: plan([item()]), destination: dest, apply: true)
        XCTAssertEqual(rows.first?.outcome, .skipped("destination exists"))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Wimm_2023-01-14_01-59-49_1928D839.m4a")), Data("old".utf8))

        rows = VoiceMemosImport.run(plan: plan([
            item(dst: "../x.m4a"),
            item(ts: "2999-01-01T00:00:00Z"),
            item(size: 99),
            item(src: "missing.m4a")
        ]), destination: dest, apply: true)
        XCTAssertEqual(rows.map { String(describing: $0.outcome) }.filter { $0.contains("imported") }.count, 0)
    }

    func testLimitCountsOnlyImportable() throws {
        try Data("12345".utf8).write(to: source.appendingPathComponent("a.m4a"))
        try Data("12345".utf8).write(to: source.appendingPathComponent("b.m4a"))
        let rows = VoiceMemosImport.run(plan: plan([
            item(src: "missing.m4a", dst: "Wimm_2020-01-01_00-00-00_AAAAAAAA.m4a"),
            item(src: "a.m4a", dst: "Wimm_2020-01-01_00-00-01_BBBBBBBB.m4a"),
            item(src: "b.m4a", dst: "Wimm_2020-01-01_00-00-02_CCCCCCCC.m4a")
        ]), destination: dest, apply: true, limit: 1)
        XCTAssertEqual(rows.filter { $0.outcome == .imported }.count, 1)
        XCTAssertEqual(rows.count, 2)
    }
}
