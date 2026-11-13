import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

final class HUDRecordingSessionTests: XCTestCase {
    private var tempDir: URL!
    private var storage: FileSystemAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-hud-recording-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = FileSystemAdapter(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testStopHUDRecordingFallsBackToLivePartialWhenFinalEmpty() async throws {
        let transcriber = HUDRecordingTranscriberStub(finalText: "   \n")
        var state: HUDRecordingState? = try startHUDRecording(transcriber: transcriber)

        let note = try await stopHUDRecording(
            transcriber: transcriber,
            storage: storage,
            recordingState: &state,
            autoProcessAfterRecord: false
        )

        XCTAssertEqual(note.text, "partial transcript")
    }

    func testCancelHUDRecordingClearsStateAndStopsCapture() async throws {
        let transcriber = HUDRecordingTranscriberStub(finalText: "unused")
        var state: HUDRecordingState? = try startHUDRecording(transcriber: transcriber)

        await cancelHUDRecording(
            transcriber: transcriber,
            recordingState: &state
        )

        XCTAssertNil(state)
        XCTAssertEqual(transcriber.stopCalls, 1)
    }
}

private final class HUDRecordingTranscriberStub: TranscriptionPort, @unchecked Sendable {
    private let lock = NSLock()
    private let finalText: String
    private(set) var stopCalls = 0

    init(finalText: String) {
        self.finalText = finalText
    }

    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("partial transcript")
            continuation.finish()
        }
    }

    func stopCapture() async throws -> (audioData: Data, finalText: String) {
        lock.withLock { stopCalls += 1 }
        return (Data([1, 2, 3]), finalText)
    }

    func transcribeFile(at fileURL: URL) async throws -> String {
        finalText
    }
}
