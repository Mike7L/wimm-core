import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class VoiceMemosServiceFieldsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vm-fields-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func make(_ name: String, _ sidecar: [String: Any]?) throws {
        try Data("audio".utf8).write(to: dir.appendingPathComponent(name))
        if let sidecar {
            try JSONSerialization.data(withJSONObject: sidecar).write(to: FileStore.metadataURL(forRecordingURL: dir.appendingPathComponent(name)))
        }
    }

    private func read(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: dir.appendingPathComponent(name)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let imported: [String: Any] = ["syncId": "S", "timestamp": "2021-04-17T11:56:49Z",
                                           "voiceMemos": ["file": "20210417 135649-3015C5D8.m4a"]]

    func testDryRunWritesNothing() throws {
        try make("a.m4a", imported)
        let before = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: dir.appendingPathComponent("a.m4a")))
        let rows = VoiceMemosServiceFields.run(notes: ["a.m4a"], directory: dir, apply: false, measure: { _ in 12.5 })
        XCTAssertEqual(rows.first?.outcome, .wouldFill(["recordingURL", "isComplete", "lastSaved", "duration"]))
        XCTAssertEqual(try Data(contentsOf: FileStore.metadataURL(forRecordingURL: dir.appendingPathComponent("a.m4a"))), before)
    }

    func testApplyAddsOnlyMissingKeysAndKeepsOthers() throws {
        var dict = imported
        dict["isComplete"] = false
        dict["duration"] = 0
        try make("a.m4a", dict)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = VoiceMemosServiceFields.run(notes: ["a.m4a"], directory: dir, apply: true, now: now, measure: { _ in 12.5 })
        XCTAssertEqual(rows.first?.outcome, .filled(["recordingURL", "lastSaved", "duration"]))
        let after = try read("a.m4a")
        XCTAssertEqual(after["isComplete"] as? Bool, false, "an existing key is never overwritten")
        XCTAssertEqual(after["duration"] as? Double, 12.5)
        XCTAssertEqual(after["lastSaved"] as? String, ISO8601DateFormatter().string(from: now))
        XCTAssertEqual(after["recordingURL"] as? String, FileStore.relativePath(for: dir.appendingPathComponent("a.m4a")))
        XCTAssertEqual(after["syncId"] as? String, "S")
        XCTAssertNotNil(after["voiceMemos"])
        // A second run finds nothing to do.
        XCTAssertEqual(VoiceMemosServiceFields.run(notes: ["a.m4a"], directory: dir, apply: true, measure: { _ in 1 }).first?.outcome, .complete)
    }

    func testSkipsNonImportsMissingFilesAndUnmeasurableAudio() throws {
        try make("plain.m4a", ["syncId": "X"])
        try make("bad.m4a", imported)
        let rows = VoiceMemosServiceFields.run(notes: ["plain.m4a", "gone.m4a", "bad.m4a"], directory: dir, apply: true,
                                               measure: { _ in nil })
        XCTAssertEqual(rows.map(\.outcome), [.skipped("not a Voice Memos import"), .skipped("media file missing"),
                                             .skipped("duration not measurable")])
        XCTAssertNil(try read("bad.m4a")["recordingURL"], "nothing is written when the duration is unknown")
    }

    func testLimitCountsOnlyNotesThatNeedWork() throws {
        var done = imported
        done["recordingURL"] = "Recordings/a.m4a"; done["isComplete"] = true; done["lastSaved"] = "x"; done["duration"] = 3.0
        try make("a.m4a", done)
        try make("b.m4a", imported)
        try make("c.m4a", imported)
        let rows = VoiceMemosServiceFields.run(notes: ["a.m4a", "b.m4a", "c.m4a"], directory: dir, apply: true, limit: 1, measure: { _ in 2 })
        XCTAssertEqual(rows.map(\.note), ["a.m4a", "b.m4a"])
        XCTAssertNil(try read("c.m4a")["recordingURL"])
    }
}
