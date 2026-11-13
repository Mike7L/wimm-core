import XCTest
@testable import WimmDomain

final class RecordingMetadataTests: XCTestCase {
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }
    
    override func tearDown() {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testLegacyMigration() throws {
        // Setup: Create a legacy metadata file (recording.metadata.json)
        // AND a recording file (recording.m4a)
        let recordingURL = tempDir.appendingPathComponent("recording.m4a")
        // Create dummy recording file
        try "audio data".write(to: recordingURL, atomically: true, encoding: .utf8)
        
        let legacyURL = tempDir.appendingPathComponent("recording.metadata.json")
        let metadata = RecordingMetadata(
            recordingURL: recordingURL,
            transcription: "Legacy Content",
            duration: 123
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: legacyURL)
        
        // Ensure new format doesn't exist yet
        let newURL = tempDir.appendingPathComponent("recording.meta.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        
        // Execute: Load for recording
        // This should trigger fallback to legacy AND migration
        let loaded = try RecordingMetadata.load(for: recordingURL)
        
        // Verify:
        XCTAssertEqual(loaded.transcription, "Legacy Content")
        
        // Check migration happened (new file exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "New meta.json should be created")
        
        // Verify content of new file
        let newData = try Data(contentsOf: newURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migratedMetadata = try decoder.decode(RecordingMetadata.self, from: newData)
        XCTAssertEqual(migratedMetadata.transcription, "Legacy Content")
    }

    func testSavePreservesSeededRecordingIdentityAndOtherSidecarFields() throws {
        let recordingURL = tempDir.appendingPathComponent("recording.m4a")
        try Data().write(to: recordingURL)
        let identity = RecordingIdentity(
            id: UUID(uuidString: "6A03CBEF-1234-5678-9ABC-DEF012345678")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        identity.persist(for: recordingURL)
        FileStore.upsertMetadata(
            for: recordingURL,
            updates: ["noteCard": ["title": "Keep me"]]
        )

        let metadata = RecordingMetadata(
            recordingURL: recordingURL,
            transcription: "Saved text",
            duration: 12,
            timestamp: identity.createdAt,
            isComplete: true
        )
        try metadata.save()

        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: recordingURL))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            json[RecordingIdentity.metadataKey] as? String,
            identity.id.uuidString
        )
        XCTAssertEqual(
            (json["noteCard"] as? [String: Any])?["title"] as? String,
            "Keep me"
        )
    }
}
