import AVFoundation
import XCTest
import WimmDomain
@testable import WimmiOSApp

final class AudioInterruptionPolicyTests: XCTestCase {
    func testCallClosesTheNoteAndPlansARestart() {
        XCTAssertEqual(
            AudioInterruptionPolicy.action(for: .began, isRecording: true, isUserPaused: false, restartPending: false),
            .finish(restartAfter: true))
    }

    func testCallDuringUserPauseClosesTheNoteWithoutRestart() {
        XCTAssertEqual(
            AudioInterruptionPolicy.action(for: .began, isRecording: true, isUserPaused: true, restartPending: false),
            .finish(restartAfter: false))
    }

    func testCallEndStartsANewNoteOnlyWhenAllowed() {
        XCTAssertEqual(
            AudioInterruptionPolicy.action(
                for: .ended(shouldResume: true), isRecording: false, isUserPaused: false, restartPending: true),
            .startNewRecording)
        XCTAssertEqual(
            AudioInterruptionPolicy.action(
                for: .ended(shouldResume: false), isRecording: false, isUserPaused: false, restartPending: true),
            .none)
        XCTAssertEqual(
            AudioInterruptionPolicy.action(
                for: .ended(shouldResume: true), isRecording: false, isUserPaused: false, restartPending: false),
            .none)
    }

    func testUserAlreadyRecordingAgainIsLeftAlone() {
        XCTAssertEqual(
            AudioInterruptionPolicy.action(
                for: .ended(shouldResume: true), isRecording: true, isUserPaused: false, restartPending: true),
            .none)
    }

    func testNothingHappensWhenNotRecording() {
        XCTAssertEqual(
            AudioInterruptionPolicy.action(for: .began, isRecording: false, isUserPaused: false, restartPending: false),
            .none)
    }

    func testNotificationUserInfoIsDecoded() {
        let began: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ]
        XCTAssertEqual(AudioInterruptionEvent(began), .began)
        let ended: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]
        XCTAssertEqual(AudioInterruptionEvent(ended), .ended(shouldResume: true))
        XCTAssertNil(AudioInterruptionEvent(nil))
    }
}

@MainActor
final class CallInterruptionFlowTests: XCTestCase {
    func testCallFinishesTheNoteLikeStopAndRestartsAfter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("before-call.m4a")
        let recorder = CallStubRecorder()
        let state = NoSyncAppState(audioRecorder: recorder, startServices: false)
        recorder.begin(at: url)
        state.showCapture = true

        await state.handleAudioInterruption(.began)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(try RecordingMetadata.load(for: url).isComplete, "The note before the call is closed")
        XCTAssertEqual(state.recordings.map(\.fileURL), [url])
        for _ in 0..<50 where state.syncedURLs.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(state.syncedURLs, [url], "Uploaded like a note stopped by hand")
        XCTAssertTrue(state.restartAfterInterruption)

        await state.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertEqual(recorder.startCount, 1, "A new note starts after the call")
        XCTAssertTrue(state.showCapture)
        XCTAssertFalse(state.restartAfterInterruption)
    }

    func testCallEndWithoutPermissionStartsNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = CallStubRecorder()
        let state = NoSyncAppState(audioRecorder: recorder, startServices: false)
        recorder.begin(at: directory.appendingPathComponent("a.m4a"))

        await state.handleAudioInterruption(.began)
        await state.handleAudioInterruption(.ended(shouldResume: false))
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertFalse(state.restartAfterInterruption)
    }
}

private final class CallStubRecorder: ReliableRecorder {
    private var url: URL?
    private(set) var startCount = 0
    override var recordingURL: URL? { url }

    func begin(at url: URL) {
        self.url = url
        isRecording = true
    }

    override func startRecording() async {
        startCount += 1
        isRecording = true
    }

    override func stopRecording() async {
        guard let url else { return }
        try! RecordingMetadata(recordingURL: url, transcription: "", duration: 5, isComplete: true).save()
        isRecording = false
        self.url = nil
    }
}

@MainActor
private final class NoSyncAppState: AppState {
    private(set) var syncedURLs: [URL] = []
    override func enqueueSync(for url: URL) async { syncedURLs.append(url) }
}
