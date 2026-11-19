import XCTest
import WimmDomain
import WimmInfrastructure
import WimmTranscription
@testable import WimmStudio

final class StudioTranscriptCatchUpTests: XCTestCase {
    private let audio = URL(fileURLWithPath: "/tmp/Wimm_2026-11-03_15-39-38_7F0604AC.m4a")

    // Which recordings need a run: TranscriptRuns.needsFileRun (NeedsFileRunTests in WimmCoreTests).

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

    func testSyncedRecordingWithOnlyLiveTextNeedsARun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let name = { (date: Date, id: String) -> URL in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return dir.appendingPathComponent("Wimm_\(f.string(from: date))_\(id).m4a")
        }
        let fresh = name(now.addingTimeInterval(-60), "AAAA0001")
        let old = name(now.addingTimeInterval(-30 * 86_400), "AAAA0002")
        for file in [fresh, old] {
            try Data([0]).write(to: file)
            let meta: [String: Any] = ["duration": 600.0, "transcription": "живой текст с iPhone"]
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: FileStore.metadataURL(forRecordingURL: file))
        }
        let queue = RetranscriptionQueue(directory: dir.appendingPathComponent("queue"))

        XCTAssertEqual(StudioTranscriptCatchUp.needingRun([fresh, old], queue: queue, minimumAge: 0, now: now), [fresh])
        XCTAssertEqual(StudioTranscriptCatchUp.needingRun([fresh], queue: queue,
                                                          minimumAge: StudioTranscriptCatchUp.minimumAge, now: now), [])
    }
}
