import AVFoundation
import XCTest
@testable import WimmInfrastructure
import WimmDomain

final class RecordedDurationTests: XCTestCase {
    func testTheFileWinsOverTheClock() {
        // The S1226 shape: the clock ran 785 s, the file kept 186 s.
        XCTAssertEqual(RecordedDuration.reconcile(clock: 784.6, file: 185.9),
                       .init(seconds: 185.9, unsavedSeconds: 784.6 - 185.9))
        // Stop latency and AAC priming are not lost audio.
        XCTAssertEqual(RecordedDuration.reconcile(clock: 120.4, file: 119.6), .init(seconds: 119.6, unsavedSeconds: 0))
        XCTAssertEqual(RecordedDuration.reconcile(clock: 60, file: 60.05), .init(seconds: 60.05, unsavedSeconds: 0))
        // An unreadable file keeps the clock.
        XCTAssertEqual(RecordedDuration.reconcile(clock: 42, file: nil), .init(seconds: 42, unsavedSeconds: 0))
        XCTAssertEqual(RecordedDuration.reconcile(clock: 42, file: 0), .init(seconds: 42, unsavedSeconds: 0))
        XCTAssertEqual(RecordedDuration.reconcile(clock: 42, file: .nan), .init(seconds: 42, unsavedSeconds: 0))
    }

    /// A real AAC file (the iPhone format) that stopped after 3 s while the
    /// clock said 10 minutes: the stated duration is the file's.
    func testReadsAFinalizedAACFile() async throws {
        let root = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("short.m4a")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames = AVAudioFrameCount(44100 * 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 1,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } // closing the file finalizes it, as the recorder's stop does

        let measured = await RecordedDuration.fileSeconds(of: url)
        let seconds = try XCTUnwrap(measured)
        XCTAssertEqual(seconds, 3, accuracy: 0.1)
        let verdict = RecordedDuration.reconcile(clock: 600, file: seconds)
        XCTAssertEqual(verdict.seconds, seconds)
        XCTAssertEqual(verdict.unsavedSeconds, 600 - seconds, accuracy: 0.001)
        let missing = await RecordedDuration.fileSeconds(of: root.appendingPathComponent("none.m4a"))
        XCTAssertNil(missing)
    }
}
