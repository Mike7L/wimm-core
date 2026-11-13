import XCTest
@testable import WimmDomain

final class IOSRecordingRepositoryTests: XCTestCase {
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

    func testInvalidatingCacheIncludesNewRecordingImmediately() async throws {
        let base = try makeEnvIsolatedBase()
        defer {
            unsetenv("WIMM_BASE_DIR")
            try? FileManager.default.removeItem(at: base)
        }
        let directory = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = IOSRecordingRepository()
        let initial = await repository.recordings()
        XCTAssertTrue(initial.isEmpty)

        let recording = directory.appendingPathComponent("new-recording.m4a")
        try Data().write(to: recording)
        await repository.invalidateCache()
        let refreshed = await repository.recordings()
        XCTAssertEqual(refreshed.map { $0.resolvingSymlinksInPath() }, [recording.resolvingSymlinksInPath()])
    }

    func testAttachments_MigratesLegacyAttachmentKeysToExtractedFields() async throws {
        let base = try makeEnvIsolatedBase()
        defer {
            unsetenv("WIMM_BASE_DIR")
            try? FileManager.default.removeItem(at: base)
        }

        let recordingsDir = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let recording = recordingsDir.appendingPathComponent("legacy-ios.m4a")
        FileManager.default.createFile(atPath: recording.path, contents: Data())

        let attachmentURL = recordingsDir.appendingPathComponent("legacy-ios.txt")
        FileManager.default.createFile(atPath: attachmentURL.path, contents: Data("hello".utf8))

        let repo = IOSRecordingRepository()
        await repo.upsertMetadata(file: recording, updates: [
            "attachments": [[
                "id": UUID().uuidString,
                "url": attachmentURL.absoluteString,
                "type": "text",
                "ocrText": "legacy text",
                "ocrProvider": "legacy-provider",
                "ocrModel": "legacy-model"
            ]]
        ])

        let attachments = await repo.attachments(for: recording)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.extractedText, "legacy text")
        XCTAssertEqual(attachments.first?.extractionProvider, "legacy-provider")
        XCTAssertEqual(attachments.first?.extractionModel, "legacy-model")

        let metaAfter = try loadMeta(for: recording)
        guard let list = metaAfter["attachments"] as? [[String: Any]],
              let first = list.first else {
            XCTFail("Missing migrated attachment metadata")
            return
        }

        XCTAssertEqual(first["extractedText"] as? String, "legacy text")
        XCTAssertEqual(first["extractionProvider"] as? String, "legacy-provider")
        XCTAssertEqual(first["extractionModel"] as? String, "legacy-model")
        XCTAssertNil(first["ocrText"])
        XCTAssertNil(first["ocrProvider"])
        XCTAssertNil(first["ocrModel"])
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

        let repo = IOSRecordingRepository()
        await repo.upsertMetadata(file: recording, updates: [
            "attachments": [[
                "id": UUID().uuidString,
                "url": attachmentURL.absoluteString,
                "type": "text"
            ]]
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        let maybeTrashedURL = await repo.moveToTrash(file: recording)
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
        await IOSRecordingRepository().upsertMetadata(file: recording, updates: ["recordingId": "R1"])

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
}
