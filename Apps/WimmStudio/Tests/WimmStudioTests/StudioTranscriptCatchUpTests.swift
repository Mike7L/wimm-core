import XCTest
import WimmDomain
import WimmInfrastructure
import WimmTranscription
@testable import WimmStudio

final class StudioTranscriptCatchUpTests: XCTestCase {
    private let audio = URL(fileURLWithPath: "/tmp/Wimm_2026-11-03_15-39-38_7F0604AC.m4a")

    func testRecordingWithOnlyIdentityNeedsTranscript() {
        XCTAssertTrue(StudioTranscriptCatchUp.needsTranscript(file: audio, meta: ["recordingId": "7F0604AC"]))
    }

    func testEmptyRunNeedsTranscript() {
        XCTAssertTrue(StudioTranscriptCatchUp.needsTranscript(file: audio, meta: ["transcription": ["transcript": "  "]]))
        XCTAssertTrue(StudioTranscriptCatchUp.needsTranscript(file: audio, meta: ["transcription": ""]))
    }

    func testTextNoSpeechAndTapsAreDone() {
        XCTAssertFalse(StudioTranscriptCatchUp.needsTranscript(file: audio, meta: ["transcription": ["transcript": "Привет"]]))
        XCTAssertFalse(StudioTranscriptCatchUp.needsTranscript(file: audio, meta: ["transcription": "Привет с iPhone"]))
        XCTAssertFalse(StudioTranscriptCatchUp.needsTranscript(
            file: audio, meta: ["transcription": ["speechStatus": TranscriptionSpeechStatus.noSpeech.rawValue]]))
        XCTAssertFalse(StudioTranscriptCatchUp.needsTranscript(file: audio, meta: ["duration": 0.4]))
    }

    func testDerivedAndNonAudioFilesAreSkipped() {
        let micro = URL(fileURLWithPath: "/tmp/Wimm_2026-11-03_15-39-38_7F0604AC_micro.m4a")
        XCTAssertFalse(StudioTranscriptCatchUp.needsTranscript(file: micro, meta: [:]))
        XCTAssertFalse(StudioTranscriptCatchUp.needsTranscript(file: URL(fileURLWithPath: "/tmp/note.txt"), meta: [:]))
    }

    func testDrainLeavesQueueToWorkerHoldingTheLock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = RetranscriptionQueue(directory: dir)
        _ = try queue.enqueue([.init(file: audio.path, noteId: "n", model: ParakeetModel.ultra,
                                     analyze: false, reason: nil, requestedAt: Date())])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // flock is per open file description, so a second open in this process conflicts too.
        let fd = open(queue.workerLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        let done = try await RetranscriptionWorker.drain(queue: queue, origin: "test", defaultReason: "test")
        XCTAssertNil(done)
        XCTAssertEqual(queue.entries().map(\.state), [.queued])
    }

    func testDrainRecordsAMissingFileAsFailed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = RetranscriptionQueue(directory: dir)
        let missing = dir.appendingPathComponent("Wimm_2026-11-03_00-00-00_DEADBEEF.m4a")
        _ = try queue.enqueue([.init(file: missing.path, noteId: "n", model: ParakeetModel.ultra,
                                     analyze: false, reason: nil, requestedAt: Date())])

        let done = try await RetranscriptionWorker.drain(queue: queue, origin: "test", defaultReason: "test")
        XCTAssertEqual(done, 1)
        XCTAssertEqual(queue.entries().map(\.state), [.failed])
        XCTAssertEqual(queue.entries().first?.outcome, "recording file missing")
    }
}
