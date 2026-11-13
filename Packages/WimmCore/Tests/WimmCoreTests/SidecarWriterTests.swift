import XCTest
@testable import WimmDomain

/// A `.meta.json` sidecar is written by several subsystems — the recorder,
/// `NoteOrigin`, CloudSync, transcription, the trash, `RecordingMetadata` —
/// often within the same second of one recording. These tests pin the two
/// properties that sharing depends on.
final class SidecarWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }

    override func tearDown() {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func sidecar(for recording: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: recording))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private final class EventCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count == 1 }
    }
    func testUnreadableSidecarIsNeverOverwritten() throws {
        let url = tempDir.appendingPathComponent("broken.meta.json")
        let garbage = Data("{\"transcription\": {\"transcript\": \"keep".utf8)
        try garbage.write(to: url)
        XCTAssertThrowsError(try FileStore.mutateSidecar(at: url) { $0["x"] = 1; return true })
        XCTAssertEqual(try Data(contentsOf: url), garbage)

        let missing = tempDir.appendingPathComponent("new.meta.json")
        try FileStore.mutateSidecar(at: missing) { $0["x"] = 1; return true }
        XCTAssertNotNil(try Data(contentsOf: missing))
    }

    func testNotificationIsDeliveredAfterUnlockAndSeesCommittedData() throws {
        let recording = tempDir.appendingPathComponent("notify.m4a")
        try Data().write(to: recording)
        let expected = FileStore.metadataURL(forRecordingURL: recording)
        let counter = EventCount()
        let observer = NotificationCenter.default.addObserver(forName: FileStore.sidecarDidChange, object: nil, queue: nil) { event in
            guard event.object as? URL == expected, counter.first() else { return }
            // This would deadlock if notification delivery still held the writer lock.
            FileStore.upsertMetadata(for: recording, updates: ["observer": true])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        FileStore.upsertMetadata(for: recording, updates: ["writer": true])
        let result = try sidecar(for: recording)
        XCTAssertEqual(result["writer"] as? Bool, true)
        XCTAssertEqual(result["observer"] as? Bool, true)
    }

    /// Writers entering through different doors must not erase each other's
    /// keys. Before every door took the shared lock, only `upsertMetadata`
    /// did — two unsynchronized read-modify-writes lose whichever lands first.
    func testConcurrentWritersThroughDifferentDoorsKeepEveryKey() throws {
        let recording = tempDir.appendingPathComponent("race.m4a")
        try Data().write(to: recording)
        let metaURL = FileStore.metadataURL(forRecordingURL: recording)
        let repo = IOSRecordingRepository()
        let writers = 60

        DispatchQueue.concurrentPerform(iterations: writers * 3) { i in
            let n = i / 3
            switch i % 3 {
            case 0:
                FileStore.upsertMetadata(for: recording, updates: ["upsert_\(n)": n])
            case 1:
                repo.upsertMetadata(file: recording, updates: ["ios_\(n)": n])
            default:
                try? FileStore.mutateSidecar(at: metaURL) { json in
                    json["direct_\(n)"] = n
                    return true
                }
            }
        }

        let json = try sidecar(for: recording)
        for n in 0..<writers {
            XCTAssertEqual(json["upsert_\(n)"] as? Int, n, "lost upsert_\(n)")
            XCTAssertEqual(json["ios_\(n)"] as? Int, n, "lost ios_\(n)")
            XCTAssertEqual(json["direct_\(n)"] as? Int, n, "lost direct_\(n)")
        }
    }

    /// `RecordingMetadata.save()` merges into the shared sidecar but writes
    /// only its own keys to the legacy `.metadata.json` copy. bf046dc turned
    /// the legacy write into a full clone of the shared sidecar by reusing a
    /// variable name.
    func testSaveMergesSharedSidecarButKeepsLegacyCopyToOwnKeys() throws {
        let recording = tempDir.appendingPathComponent("legacy.m4a")
        try Data().write(to: recording)
        FileStore.upsertMetadata(for: recording, updates: ["origin": ["platform": "iPhone"]])

        try RecordingMetadata(recordingURL: recording, transcription: "hello").save()

        let shared = try sidecar(for: recording)
        XCTAssertNotNil(shared["origin"], "save() must not drop a key another writer owns")
        XCTAssertEqual(shared["transcription"] as? String, "hello")

        let legacyData = try Data(contentsOf: RecordingMetadata.legacyMetadataURL(for: recording))
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(legacy["origin"], "legacy copy must hold RecordingMetadata's own keys only")
        XCTAssertEqual(legacy["transcription"] as? String, "hello")
    }

    /// A non-JSON value must surface as a thrown error. Handing it to
    /// `JSONSerialization` raises an Objective-C exception, which crashes.
    func testInvalidValueThrowsInsteadOfCrashing() throws {
        let url = tempDir.appendingPathComponent("bad.meta.json")
        XCTAssertThrowsError(try FileStore.mutateSidecar(at: url) { json in
            json["date"] = Date()
            return true
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
