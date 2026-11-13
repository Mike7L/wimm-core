import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

final class FileSystemAdapterTests: XCTestCase {
    private var tempDir: URL!
    private var adapter: FileSystemAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        adapter = FileSystemAdapter(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadAndUpdatePreservesUnknownSidecarFields() async throws {
        let id = UUID()
        let sidecar = tempDir.appendingPathComponent("sample.meta.json")
        let payload: [String: Any] = [
            "id": id.uuidString,
            "createdAt": "2026-02-17T10:11:12Z",
            "text": "legacy text",
            "unknownField": "must_stay"
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sidecar, options: .atomic)

        let notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].id, id)
        XCTAssertEqual(notes[0].text, "legacy text")

        var updated = notes[0]
        updated.text = "updated text"
        try await adapter.updateNote(updated)

        let saved = try Data(contentsOf: sidecar)
        let savedJSON = try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        XCTAssertEqual(savedJSON?["unknownField"] as? String, "must_stay")
        XCTAssertEqual(savedJSON?["text"] as? String, "updated text")
    }

    func testLoadLegacyNoteCardMapsToCompletedStatus() async throws {
        let id = UUID()
        let sidecar = tempDir.appendingPathComponent("card.meta.json")
        let payload: [String: Any] = [
            "id": id.uuidString,
            "text": "note text",
            "noteCard": [
                "title": "T",
                "summary": "S",
                "tags": ["a"],
                "projects": ["p1"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecar, options: .atomic)

        let notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].id, id)
        XCTAssertNotNil(notes[0].card)
        XCTAssertEqual(notes[0].status, .completed)
    }

    func testLoadLegacyWimmTranscriptionTranscriptText() async throws {
        let sidecar = tempDir.appendingPathComponent("Новая запись 43.meta.json")
        let audio = tempDir.appendingPathComponent("Новая запись 43.m4a")
        try Data([0x00, 0x01]).write(to: audio, options: .atomic)
        let payload: [String: Any] = [
            "sourcePath": "/Users/example/Downloads/Новая запись 43.m4a",
            "transcription": [
                "provider": "gemini",
                "model": "gemini-2.5-flash",
                "transcript": "Legacy transcript from Wimm metadata"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecar, options: .atomic)

        let notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "Legacy transcript from Wimm metadata")
        XCTAssertEqual(notes[0].audioPath, "Новая запись 43.m4a")
        XCTAssertEqual(notes[0].status, .pendingAnalysis)

        let adapter2 = FileSystemAdapter(rootDirectory: tempDir)
        let reloaded = try await adapter2.loadAll()
        XCTAssertEqual(reloaded[0].id, notes[0].id)
    }

    func testPersistsRetryableFlagInSidecar() async throws {
        let id = UUID()
        let sidecar = tempDir.appendingPathComponent("failed.meta.json")
        let payload: [String: Any] = [
            "id": id.uuidString,
            "text": "x",
            "wimmStatus": "failed",
            "wimmErrorReason": "rate limit",
            "wimmRetryable": true
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecar, options: .atomic)

        var notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        if case let .failed(reason, retryable) = notes[0].status {
            XCTAssertEqual(reason, "rate limit")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("Expected failed status")
        }

        notes[0].status = .failed(reason: "still failing", retryable: false)
        try await adapter.updateNote(notes[0])

        let saved = try Data(contentsOf: sidecar)
        let savedJSON = try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        XCTAssertEqual(savedJSON?["wimmStatus"] as? String, "failed")
        XCTAssertEqual(savedJSON?["wimmRetryable"] as? Bool, false)
    }

    func testLoadsLegacyStatusKeysFromSidecar() async throws {
        let id = UUID()
        let sidecar = tempDir.appendingPathComponent("legacy_status.meta.json")
        let legacyStatusKey = "mem" + "arioStatus"
        let legacyReasonKey = "mem" + "arioErrorReason"
        let legacyRetryableKey = "mem" + "arioRetryable"
        let payload: [String: Any] = [
            "id": id.uuidString,
            "text": "x",
            legacyStatusKey: "failed",
            legacyReasonKey: "timeout",
            legacyRetryableKey: true
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecar, options: .atomic)

        let notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        if case let .failed(reason, retryable) = notes[0].status {
            XCTAssertEqual(reason, "timeout")
            XCTAssertTrue(retryable)
        } else {
            XCTFail("Expected failed status from legacy keys")
        }
    }

    func testNoteCardBooleanFlagsRoundTrip() async throws {
        let id = UUID()
        let sidecarPath = tempDir.appendingPathComponent("card_flags.meta.json")
        let payload: [String: Any] = [
            "id": id.uuidString,
            "text": "insight about testing",
            "noteCard": [
                "title": "Testing Insights",
                "summary": "A brief summary.",
                "tags": ["testing"],
                "projects": ["WIMM"],
                "is_artifact": true,
                "is_draft": false,
                "is_insight": true,
                "is_liked": false
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecarPath, options: .atomic)

        let notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        let card = try XCTUnwrap(notes[0].card)
        XCTAssertTrue(card.isArtifact)
        XCTAssertFalse(card.isDraft)
        XCTAssertTrue(card.isInsight)
        XCTAssertFalse(card.isLiked)

        // Mutate and persist
        var updated = notes[0]
        updated.card?.isLiked = true
        updated.card?.isDraft = true
        try await adapter.updateNote(updated)

        // Re-read from disk
        let adapter2 = FileSystemAdapter(rootDirectory: tempDir)
        let reloaded = try await adapter2.loadAll()
        let reloadedCard = try XCTUnwrap(reloaded[0].card)
        XCTAssertTrue(reloadedCard.isArtifact)
        XCTAssertTrue(reloadedCard.isDraft)
        XCTAssertTrue(reloadedCard.isInsight)
        XCTAssertTrue(reloadedCard.isLiked)

        // Verify raw JSON on disk
        let saved = try Data(contentsOf: sidecarPath)
        let savedJSON = try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        let noteCardJSON = try XCTUnwrap(savedJSON?["noteCard"] as? [String: Any])
        XCTAssertEqual(noteCardJSON["is_artifact"] as? Bool, true)
        XCTAssertEqual(noteCardJSON["is_draft"]    as? Bool, true)
        XCTAssertEqual(noteCardJSON["is_insight"]  as? Bool, true)
        XCTAssertEqual(noteCardJSON["is_liked"]    as? Bool, true)
    }

    func testLegacySidecarWithoutCreatedAtUsesFileTimestamp() async throws {
        let id = UUID()
        let sidecar = tempDir.appendingPathComponent("legacy_without_date.meta.json")
        let payload: [String: Any] = [
            "id": id.uuidString,
            "text": "",
            "status": "failed"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecar, options: .atomic)

        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: expectedDate, .modificationDate: expectedDate],
            ofItemAtPath: sidecar.path
        )

        let notes = try await adapter.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].id, id)
        XCTAssertEqual(notes[0].createdAt.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 2.0)
    }
}
