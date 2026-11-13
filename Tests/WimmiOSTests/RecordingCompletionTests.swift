import XCTest
import WimmDomain
@testable import WimmiOSApp

@MainActor
final class RecordingCompletionTests: XCTestCase {
    func testFinishPublishesLocallyAndAllowsNextRecordingWhileUploadIsSuspended() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.m4a")
        let secondURL = directory.appendingPathComponent("second.m4a")
        let recorder = StubRecorder()
        let state = SuspendedSyncAppState(audioRecorder: recorder, startServices: false)

        recorder.begin(at: firstURL, transcript: "Первая заметка. Продолжение.")
        state.showCapture = true
        await state.finishRecording()
        await fulfillment(of: [state.syncStarted], timeout: 2)

        XCTAssertFalse(state.showCapture)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(state.recordings.map(\.fileURL), [firstURL])
        XCTAssertEqual(state.recordings.first?.note?.summary, "Первая заметка. Продолжение.")
        XCTAssertTrue(try RecordingMetadata.load(for: firstURL).isComplete)
        XCTAssertEqual(state.uploadedURLs, [firstURL])
        XCTAssertEqual(state.recordings.first?.durationSeconds, 12)
        XCTAssertEqual(state.recordings.first?.note?.title, "Первая заметка")
        await state.finishRecording()
        XCTAssertEqual(state.uploadedURLs, [firstURL], "Repeated stop must not schedule another upload")

        // A new capture is usable before the first upload is allowed to finish.
        recorder.begin(at: secondURL, transcript: "Вторая заметка")
        state.showCapture = true
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.recordingURL, secondURL)

        state.releaseSync()
        await fulfillment(of: [state.syncFinished], timeout: 2)
        XCTAssertTrue(state.showCapture, "The old upload must not close a newer capture")
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.transcribedText, "Вторая заметка")
        XCTAssertEqual(state.recordings.first?.note?.refined_text, "Первая заметка. Продолжение.")
    }

    func testRemoteStopUsesTheSameNonblockingCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("remote.m4a")
        let recorder = StubRecorder()
        let state = SuspendedSyncAppState(audioRecorder: recorder, startServices: false)
        recorder.begin(at: url, transcript: "Системная кнопка")
        state.showCapture = true

        await state.handleGlobalPlayPause()
        await fulfillment(of: [state.syncStarted], timeout: 2)
        XCTAssertFalse(state.showCapture)
        XCTAssertEqual(state.recordings.first?.note?.summary, "Системная кнопка")
        state.releaseSync()
        await fulfillment(of: [state.syncFinished], timeout: 2)
    }
}

@MainActor
private final class StubRecorder: ReliableRecorder {
    private var url: URL?
    override var recordingURL: URL? { url }

    func begin(at url: URL, transcript: String) {
        self.url = url
        transcribedText = transcript
        isRecording = true
    }

    override func stopRecording() async {
        guard let url else { return }
        try! RecordingMetadata(
            recordingURL: url,
            transcription: transcribedText,
            duration: 12,
            isComplete: true
        ).save()
        isRecording = false
        self.url = nil
    }
}

@MainActor
private final class SuspendedSyncAppState: AppState {
    let syncStarted = XCTestExpectation(description: "Upload started")
    let syncFinished = XCTestExpectation(description: "Upload finished")
    private(set) var uploadedURLs: [URL] = []
    private var continuation: CheckedContinuation<Void, Never>?

    override func enqueueSync(for url: URL) async {
        uploadedURLs.append(url)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            syncStarted.fulfill()
        }
        syncFinished.fulfill()
    }

    func releaseSync() {
        continuation?.resume()
        continuation = nil
    }
}
