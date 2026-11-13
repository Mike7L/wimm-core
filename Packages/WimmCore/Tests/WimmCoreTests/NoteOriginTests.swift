import XCTest
@testable import WimmDomain

final class NoteOriginTests: XCTestCase {
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

    // MARK: - displayString

    func testDisplayStringFromFullOrigin() {
        let meta: [String: Any] = ["origin": ["platform": "macOS", "device": "Michas-MacBook-Pro"]]
        XCTAssertEqual(
            NoteOrigin.displayString(metadata: meta, fileName: "Wimm_2026-07-19_10-00-00.m4a"),
            "macOS · Michas-MacBook-Pro"
        )
    }

    func testDisplayStringCollapsesEqualPlatformAndDevice() {
        let meta: [String: Any] = ["origin": ["platform": "iPhone", "device": "iPhone"]]
        XCTAssertEqual(NoteOrigin.displayString(metadata: meta, fileName: "x.m4a"), "iPhone")
    }

    func testDisplayStringPlatformOnly() {
        let meta: [String: Any] = ["origin": ["platform": "iPad"]]
        XCTAssertEqual(NoteOrigin.displayString(metadata: meta, fileName: "x.m4a"), "iPad")
    }

    func testDisplayStringFallsBackToRecordingPrefix() {
        XCTAssertEqual(
            NoteOrigin.displayString(metadata: [:], fileName: "recording_2026-07-19T10:00:00Z.m4a"),
            "iPhone"
        )
    }

    func testDisplayStringUnknownForAmbiguousWimmPrefix() {
        XCTAssertNil(
            NoteOrigin.displayString(metadata: [:], fileName: "Wimm_2026-07-19_10-00-00.m4a")
        )
    }

    // MARK: - stamp + sidecar interplay

    func testInputDeviceAppearsAlongsideRecordingOrigin() {
        let meta: [String: Any] = [
            "origin": ["platform": "macOS", "device": "MacBook"],
            "audioInput": ["name": "AirPods Pro", "transport": "bluetooth"]
        ]
        XCTAssertEqual(NoteOrigin.displayString(metadata: meta, fileName: "x.m4a"),
                       "macOS · MacBook · AirPods Pro")
        XCTAssertNil(RecordingInputDevice.displayName(metadata: ["audioInput": ["name": "  "]]))
    }

    func testInputDeviceSurvivesOriginStampAndRecorderAutosave() throws {
        let url = tempDir.appendingPathComponent("input.m4a")
        RecordingInputDevice(name: "USB Microphone", transport: "usb").stamp(url)
        NoteOrigin.stamp(url)
        try RecordingMetadata(recordingURL: url, transcription: "Hello").save()
        let data = try Data(contentsOf: RecordingMetadata.metadataURL(for: url))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(RecordingInputDevice.displayName(metadata: meta), "USB Microphone")
        XCTAssertEqual((meta["audioInput"] as? [String: String])?["transport"], "usb")
        XCTAssertEqual(meta["transcription"] as? String, "Hello")
    }

    func testStampWritesOriginIntoSidecar() throws {
        let recordingURL = tempDir.appendingPathComponent("Wimm_2026-07-19_10-00-00.m4a")
        try Data("audio".utf8).write(to: recordingURL)

        NoteOrigin.stamp(recordingURL)

        let metaURL = tempDir.appendingPathComponent("Wimm_2026-07-19_10-00-00.meta.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metaURL)) as? [String: Any]
        let origin = json?["origin"] as? [String: Any]
        XCTAssertEqual(origin?["platform"] as? String, NoteOrigin.currentPlatform)
        XCTAssertEqual(origin?["device"] as? String, NoteOrigin.currentDevice)
    }

    /// RecordingMetadata.save() must merge into the shared sidecar, not wipe
    /// keys owned by other writers (origin, noteCard, …).
    func testRecordingMetadataSavePreservesOriginAndForeignKeys() throws {
        let recordingURL = tempDir.appendingPathComponent("recording_test.m4a")
        try Data("audio".utf8).write(to: recordingURL)

        NoteOrigin.stamp(recordingURL)
        FileStore.upsertMetadata(for: recordingURL, updates: ["noteCard": ["title": "Kept"]])

        let metadata = RecordingMetadata(recordingURL: recordingURL, transcription: "Hello")
        try metadata.save()

        let metaURL = tempDir.appendingPathComponent("recording_test.meta.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metaURL)) as? [String: Any]
        XCTAssertEqual((json?["origin"] as? [String: Any])?["platform"] as? String,
                       NoteOrigin.currentPlatform)
        XCTAssertEqual((json?["noteCard"] as? [String: Any])?["title"] as? String, "Kept")
        XCTAssertEqual(json?["transcription"] as? String, "Hello")

        let reloaded = try RecordingMetadata.load(for: recordingURL)
        XCTAssertEqual(reloaded.transcription, "Hello")
    }
}
