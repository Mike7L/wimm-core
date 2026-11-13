import Foundation
import SQLite3
import XCTest
@testable import WimmSecretary

final class SecretarySessionStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secretary-storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func url(_ id: String) -> URL { root.appendingPathComponent("AgentState/SecretaryFileSessions/\(id).json") }

    private func state(_ id: String, changedRow: Int? = nil, phase: String = "prepared", document: URL? = nil) -> SecretaryPacketFiles.State {
        let rows = (0..<1_000).map { (i: Int) -> String in
            "    {\"source_id\":\"S\(i)\",\"reason\":\"" + String(repeating: "Ёж 🦔 сохраняет точный текст. ", count: 8)
                + (changedRow == i ? "changed" : "original") + "\"}"
        }.joined(separator: ",\n")
        return SecretaryPacketFiles.State(id: id, document: document ?? root.appendingPathComponent("docs/document.md"),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), cli: root.appendingPathComponent("unused-cli"), sourceLimit: 64_000,
            documentData: Data("# Документ\n\nТочный текст.\n".utf8),
            registryData: Data("{\n  \"sources\": [\n\(rows)\n  ]\n}".utf8), queueData: Data(),
            policy: "Keep exact evidence", workspacePolicy: Data("policy".utf8), threadsData: Data(),
            input: Data("{\"sources\":[]}".utf8), newSources: Data("[]".utf8), receipts: [], phase: phase)
    }

    private func sql(_ statement: String, at session: URL) throws -> Int64 {
        var handle: OpaquePointer?
        let path = SecretarySessionStorage.directory(for: session).appendingPathComponent("objects.sqlite3").path
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(handle) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, statement, -1, &query, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 2) }
        defer { sqlite3_finalize(query) }
        let result = sqlite3_step(query)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw NSError(domain: "sqlite", code: 3) }
        return result == SQLITE_ROW ? sqlite3_column_int64(query, 0) : 0
    }

    func testLegacyJSONUpgradesOnlyAfterVerifiedRoundTrip() throws {
        let original = state("20261109-010000-aaaa"), session = url(original.id)
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(original).write(to: session)
        XCTAssertEqual(try SecretarySessionStorage.canonical(SecretarySessionStorage.load(from: session)),
                       try SecretarySessionStorage.canonical(original))
        try SecretarySessionStorage.save(original, to: session)
        let restored = try SecretarySessionStorage.load(from: session)
        XCTAssertEqual(try SecretarySessionStorage.canonical(restored), try SecretarySessionStorage.canonical(original))
        XCTAssertLessThan(try Data(contentsOf: session).count, original.registryData.count / 20)
        XCTAssertEqual(restored.registryData, original.registryData)
        XCTAssertEqual(restored.queueData, Data())
    }

    func testOneChangedSourceSharesOtherChunksAndKeepsBothVersions() throws {
        let first = state("20261109-010000-aaaa"), second = state("20261109-010100-bbbb", changedRow: 500)
        try SecretarySessionStorage.save(first, to: url(first.id))
        let before = try sql("SELECT COUNT(*) FROM chunks", at: url(first.id))
        try SecretarySessionStorage.save(second, to: url(second.id))
        let after = try sql("SELECT COUNT(*) FROM chunks", at: url(second.id))
        XCTAssertGreaterThan(before, 900)
        XCTAssertEqual(after - before, 1, "Only the changed registry fragment should be added")
        XCTAssertEqual(try SecretarySessionStorage.load(from: url(first.id)).registryData, first.registryData)
        XCTAssertEqual(try SecretarySessionStorage.load(from: url(second.id)).registryData, second.registryData)
    }

    func testCorruptedChunkFailsClosedWithoutReplacingTheManifest() throws {
        let original = state("20261109-010000-aaaa"), session = url(original.id)
        try SecretarySessionStorage.save(original, to: session)
        let before = try Data(contentsOf: session)
        _ = try sql("UPDATE chunks SET data=X'00010203' WHERE id=(SELECT MIN(id) FROM chunks)", at: session)
        XCTAssertThrowsError(try SecretarySessionStorage.load(from: session))
        XCTAssertThrowsError(try SecretarySessionStorage.save(original, to: session))
        XCTAssertEqual(try Data(contentsOf: session), before)
    }

    func testFailedDatabaseWriteKeepsReadableLegacyState() throws {
        let original = state("20261109-010000-aaaa"), session = url(original.id)
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = try JSONEncoder().encode(original)
        try legacy.write(to: session)
        let archive = SecretarySessionStorage.directory(for: session)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: archive.appendingPathComponent("objects.sqlite3"))
        XCTAssertThrowsError(try SecretarySessionStorage.save(original, to: session))
        XCTAssertEqual(try Data(contentsOf: session), legacy)
        XCTAssertEqual(try SecretarySessionStorage.load(from: session).registryData, original.registryData)
    }

    func testFullCheckpointsSurviveMissingSharedDatabaseAndRepeatedFindingsAreDeduplicated() throws {
        var first = state("20261109-010000-aaaa", phase: "failed")
        first.report = try JSONSerialization.data(withJSONObject: ["committed": true, "findings": ["S7285: missing source"]])
        var second = state("20261109-010100-bbbb", changedRow: 500, phase: "failed")
        second.report = first.report
        try SecretarySessionStorage.save(first, to: url(first.id))
        try SecretarySessionStorage.save(second, to: url(second.id))
        let root = SecretarySessionStorage.directory(for: url(first.id))
        let directory = SecretarySessionStorage.checkpointDirectory(document: first.document, archive: root)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("finding-") }.count, 1)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasSuffix(".json.lzfse") }.count, 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("objects.sqlite3"))
        XCTAssertThrowsError(try SecretarySessionStorage.load(from: url(first.id)))
        for file in files where file.lastPathComponent.hasSuffix(".json.lzfse") {
            let data = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
            let restored = try JSONDecoder().decode(SecretaryPacketFiles.State.self, from: data)
            let expected = restored.id == first.id ? first : second
            XCTAssertEqual(try SecretarySessionStorage.canonical(restored), try SecretarySessionStorage.canonical(expected))
        }
    }

    func testCollectionPreservesSharedHistoryAndOnlyRemovesUnreferencedData() throws {
        let first = state("20261109-010000-aaaa"), copy = state("20261109-010100-bbbb")
        try SecretarySessionStorage.save(first, to: url(first.id))
        let baseline = try sql("SELECT COUNT(*) FROM chunks", at: url(first.id))
        try SecretarySessionStorage.save(copy, to: url(copy.id))
        let changed = state(first.id, changedRow: 500)
        try SecretarySessionStorage.save(changed, to: url(first.id))
        try SecretarySessionStorage.collectUnreferenced(at: url(first.id))
        XCTAssertEqual(try sql("SELECT COUNT(*) FROM chunks", at: url(first.id)), baseline + 1)
        XCTAssertEqual(try SecretarySessionStorage.load(from: url(copy.id)).registryData, first.registryData)
        try FileManager.default.removeItem(at: url(copy.id))
        try SecretarySessionStorage.collectUnreferenced(at: url(first.id))
        XCTAssertEqual(try sql("SELECT COUNT(*) FROM chunks", at: url(first.id)), baseline)
        XCTAssertEqual(try SecretarySessionStorage.load(from: url(first.id)).registryData, changed.registryData)
    }

    func testUnreadableManifestPreventsCollection() throws {
        let first = state("20261109-010000-aaaa"), session = url(first.id)
        try SecretarySessionStorage.save(first, to: session)
        try SecretarySessionStorage.save(state(first.id, changedRow: 500), to: session)
        let before = try sql("SELECT COUNT(*) FROM chunks", at: session)
        try Data("damaged manifest".utf8).write(to: url("broken"))
        XCTAssertThrowsError(try SecretarySessionStorage.collectUnreferenced(at: session))
        XCTAssertEqual(try sql("SELECT COUNT(*) FROM chunks", at: session), before)
        XCTAssertNoThrow(try SecretarySessionStorage.load(from: session))
    }

    func testCheckpointIncludesPostPassFilesAndCapturesResolution() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary/protocol"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let document = root.appendingPathComponent("docs/document.md")
        try Data("# Result after the pass\n".utf8).write(to: document)
        try Data("{\"sources\":[]}".utf8).write(to: document.deletingPathExtension().appendingPathExtension("sources.json"))
        var failed = state("20261109-010000-aaaa", phase: "failed")
        failed.report = try JSONSerialization.data(withJSONObject: ["findings": ["old missing source"], "committed": true])
        try SecretarySessionStorage.save(failed, to: url(failed.id))
        var success = state("20261109-010100-bbbb", phase: "applied")
        success.report = try JSONSerialization.data(withJSONObject: ["findings": [], "committed": true])
        let run = root.appendingPathComponent("secretary/runs/" + success.id)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data("{\"edits\":[]}".utf8).write(to: run.appendingPathComponent("response.json"))
        try SecretarySessionStorage.save(success, to: url(success.id))
        let directory = SecretarySessionStorage.checkpointDirectory(document: success.document, archive: SecretarySessionStorage.directory(for: url(success.id)))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "first-success.json" })
        let resolved = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("resolved-") })
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as! [String: Any]
        let checkpoint = directory.appendingPathComponent((metadata["sha256"] as! String) + ".json.lzfse")
        let full = try SecretarySessionStorage.checkpointData(from: checkpoint)
        let object = try JSONSerialization.jsonObject(with: full) as! [String: Any]
        let evidence = object["_checkpoint_files"] as! [String: String]
        XCTAssertEqual(evidence["docs/document.md"].flatMap { Data(base64Encoded: $0) }, try Data(contentsOf: document))
        XCTAssertNotNil(evidence["secretary/runs/\(success.id)/response.json"])
        XCTAssertEqual(try JSONDecoder().decode(SecretaryPacketFiles.State.self, from: full).documentData, success.documentData)
    }

    func testOlderDailyPointsThinWithoutRemovingSessionHistory() throws {
        let ids = ["20200101-010000-aaaa", "20200102-010000-bbbb", "20200201-010000-cccc"]
        for id in ids { try SecretarySessionStorage.save(state(id, phase: "applied"), to: url(id)) }
        let directory = SecretarySessionStorage.checkpointDirectory(document: state(ids[0]).document, archive: SecretarySessionStorage.directory(for: url(ids[0])))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let days = files.filter { $0.lastPathComponent.hasSuffix("-latest.json") }.map(\.lastPathComponent).sorted()
        XCTAssertEqual(days, ["20200102-latest.json", "20200201-latest.json"])
        for id in ids { XCTAssertEqual(try SecretarySessionStorage.load(from: url(id)).id, id) }
    }

    func testCheckpointHistoryAndResolutionsAreScopedToDocument() throws {
        var failed = state("20261109-010000-aaaa", phase: "failed")
        failed.report = try JSONSerialization.data(withJSONObject: ["findings": ["missing source"]])
        var other = state("20261109-010100-bbbb", phase: "applied", document: root.appendingPathComponent("other/docs/other.md"))
        other.report = try JSONSerialization.data(withJSONObject: ["findings": []])
        try SecretarySessionStorage.save(failed, to: url(failed.id))
        try SecretarySessionStorage.save(other, to: url(other.id))
        let archive = SecretarySessionStorage.directory(for: url(failed.id))
        let firstDirectory = SecretarySessionStorage.checkpointDirectory(document: failed.document, archive: archive)
        let otherDirectory = SecretarySessionStorage.checkpointDirectory(document: other.document, archive: archive)
        XCTAssertNotEqual(firstDirectory, otherDirectory)
        for directory in [firstDirectory, otherDirectory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.json").path))
        }
        let files = try FileManager.default.contentsOfDirectory(at: otherDirectory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("resolved-") }, "A successful pass on another document cannot resolve this document's finding")
        XCTAssertEqual(try SecretarySessionStorage.load(from: url(failed.id)).report, failed.report)
    }

    func testCorruptedChunkInventoryStopsCollectionAndKeepsRecoverableChunks() throws {
        let original = state("20261109-010000-aaaa"), session = url(original.id)
        try SecretarySessionStorage.save(original, to: session)
        var handle: OpaquePointer?
        let path = SecretarySessionStorage.directory(for: session).appendingPathComponent("objects.sqlite3").path
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let row: (String, Data) = try {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT sha,refs FROM blobs ORDER BY size DESC LIMIT 1", -1, &query, nil) == SQLITE_OK,
                  sqlite3_step(query) == SQLITE_ROW else { throw NSError(domain: "sqlite", code: 4) }
            defer { sqlite3_finalize(query) }
            return (String(cString: sqlite3_column_text(query, 0)),
                    Data(bytes: sqlite3_column_blob(query, 1)!, count: Int(sqlite3_column_bytes(query, 1))))
        }()
        var ids = try JSONDecoder().decode([Int64].self, from: (row.1 as NSData).decompressed(using: .lzfse) as Data)
        ids[0] = ids[1] // Valid compression/JSON, but an incorrect reference inventory.
        let damaged = try (JSONEncoder().encode(ids) as NSData).compressed(using: .lzfse) as Data
        func replace(_ bytes: Data) {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sqlite3_exec(handle, "UPDATE blobs SET refs=X'\(hex)' WHERE sha='\(row.0)'", nil, nil, nil), SQLITE_OK)
        }
        let before = try sql("SELECT COUNT(*) FROM chunks", at: session)
        replace(damaged)
        XCTAssertThrowsError(try SecretarySessionStorage.collectUnreferenced(at: session))
        XCTAssertEqual(try sql("SELECT COUNT(*) FROM chunks", at: session), before)
        replace(row.1)
        XCTAssertEqual(try SecretarySessionStorage.load(from: session).registryData, original.registryData)
    }

    func testSameSecondRandomSuffixDoesNotHideTheLatestCompletionOrResolution() throws {
        var failed = state("20261109-010000-ffff", phase: "failed")
        failed.report = try JSONSerialization.data(withJSONObject: ["findings": ["missing source"]])
        var success = state("20261109-010000-0000", phase: "applied")
        success.report = try JSONSerialization.data(withJSONObject: ["findings": []])
        try SecretarySessionStorage.save(failed, to: url(failed.id))
        try SecretarySessionStorage.save(success, to: url(success.id))
        let directory = SecretarySessionStorage.checkpointDirectory(document: success.document, archive: SecretarySessionStorage.directory(for: url(success.id)))
        let latest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("20261109-latest.json"))) as! [String: Any]
        XCTAssertEqual(latest["runID"] as? String, success.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix("resolved-") })
    }
}
