import XCTest
@testable import WimmDomain
@testable import WimmInfrastructure

final class RecordingTrashAndAttachmentReadTests: XCTestCase {
    private func makeEnvIsolatedBase() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-ios-rec-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tmp.path, 1)
        return tmp
    }

    // Reads .meta.json from disk directly: the actor's metadata(for:)
    // returns a non-Sendable [String: Any], which Swift 6 forbids
    // crossing the isolation boundary into the test.
    private func loadMeta(for url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: url))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMoveToTrash_MovesReferencedAttachmentsAndRewritesMetadata() async throws {
        let base = try makeEnvIsolatedBase()
        defer {
            unsetenv("WIMM_BASE_DIR")
            try? FileManager.default.removeItem(at: base)
        }

        let recordingsDir = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let recording = recordingsDir.appendingPathComponent("ios-trash.m4a")
        let metadataURL = FileStore.metadataURL(forRecordingURL: recording)
        let attachmentURL = recordingsDir.appendingPathComponent("ios-trash_Attach_clip.txt")
        FileManager.default.createFile(atPath: recording.path, contents: Data())
        FileManager.default.createFile(atPath: attachmentURL.path, contents: Data("hello".utf8))

        FileStore.upsertMetadata(for: recording, updates: [
            "attachments": [[
                "id": UUID().uuidString,
                "url": attachmentURL.absoluteString,
                "type": "text"
            ]]
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        let maybeTrashedURL = await TrashRepository().moveToTrash(file: recording)
        let trashedURL = try XCTUnwrap(maybeTrashedURL)
        let trashedAttachmentURL = FileStore.trashDirectory().appendingPathComponent(attachmentURL.lastPathComponent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedAttachmentURL.path))

        let trashedMetadata = try loadMeta(for: trashedURL)
        let attachments = try XCTUnwrap(trashedMetadata["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["url"] as? String, trashedAttachmentURL.absoluteString)
    }

    /// Every delete path marks the trashed sidecar in one place, and a restore
    /// clears the marker (iOS used to leave Trash sidecars unmarked).
    func testTrashMarkerIsWrittenOnMoveAndClearedOnRestore() async throws {
        let base = try makeEnvIsolatedBase()
        defer {
            unsetenv("WIMM_BASE_DIR")
            try? FileManager.default.removeItem(at: base)
        }
        let recordingsDir = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let recording = recordingsDir.appendingPathComponent("marker.m4a")
        FileManager.default.createFile(atPath: recording.path, contents: Data("orig".utf8))
        FileStore.upsertMetadata(for: recording, updates: ["recordingId": "R1"])

        let trashed = try XCTUnwrap(RecordingTrashSupport.moveToTrash(file: recording))
        let marked = try loadMeta(for: trashed)
        XCTAssertEqual(marked["trashed"] as? Bool, true)
        XCTAssertNotNil(marked["trashedAt"] as? String)
        XCTAssertEqual(marked["originalPath"] as? String, recording.path)

        let restored = try XCTUnwrap(RecordingTrashSupport.restoreFromTrash(file: trashed))
        let cleared = try loadMeta(for: restored)
        for key in RecordingTrashSupport.markerKeys { XCTAssertNil(cleared[key], key) }
        XCTAssertEqual(cleared["recordingId"] as? String, "R1")
    }

    func testMoveToTrash_MovesMicroCopyAndRestoreBringsItBack() async throws {
        let base = try makeEnvIsolatedBase()
        defer {
            unsetenv("WIMM_BASE_DIR")
            try? FileManager.default.removeItem(at: base)
        }

        let recordingsDir = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let recording = recordingsDir.appendingPathComponent("micro-trash.m4a")
        let micro = FileStore.microURL(forRecordingURL: recording)
        FileManager.default.createFile(atPath: recording.path, contents: Data("orig".utf8))
        FileManager.default.createFile(atPath: micro.path, contents: Data("micro".utf8))

        let trashed = try XCTUnwrap(RecordingTrashSupport.moveToTrash(file: recording))
        let trashedMicro = FileStore.trashDirectory().appendingPathComponent(micro.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micro.path), "_micro must not stay behind as an orphan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedMicro.path))

        _ = try XCTUnwrap(RecordingTrashSupport.restoreFromTrash(file: trashed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micro.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedMicro.path))
    }

    func testRecoveryFindsOnlyIncompleteAudioOriginals() throws {
        let base = try makeEnvIsolatedBase()
        defer {
            unsetenv("WIMM_BASE_DIR")
            try? FileManager.default.removeItem(at: base)
        }
        let dir = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let open = dir.appendingPathComponent("Wimm_2026-11-21_10-00-00_aaaaaaaa.m4a")
        let done = dir.appendingPathComponent("Wimm_2026-11-21_11-00-00_bbbbbbbb.m4a")
        for url in [open, done] { FileManager.default.createFile(atPath: url.path, contents: Data("a".utf8)) }
        FileManager.default.createFile(atPath: FileStore.microURL(forRecordingURL: open).path, contents: Data("m".utf8))
        var openMeta = RecordingMetadata(recordingURL: open)
        openMeta.isComplete = false
        try openMeta.save()
        var doneMeta = RecordingMetadata(recordingURL: done)
        doneMeta.isComplete = true
        try doneMeta.save()

        XCTAssertEqual(RecordingRecovery.incompleteRecordings().map(\.lastPathComponent), [open.lastPathComponent])
        try RecordingRecovery.markAsComplete(open)
        XCTAssertTrue(RecordingRecovery.incompleteRecordings().isEmpty)
    }
}
