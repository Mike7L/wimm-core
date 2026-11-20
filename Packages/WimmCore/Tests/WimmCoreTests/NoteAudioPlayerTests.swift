import AVFoundation
import XCTest
@testable import WimmInfrastructure
import WimmDomain

@MainActor
final class NoteAudioPlayerTests: XCTestCase {
    private func writeRawADTSAAC(to url: URL, leadingSilenceSeconds: Int, signalSeconds: Int) throws {
        let sampleRate = 48_000.0
        let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ], commonFormat: pcm.commonFormat, interleaved: pcm.isInterleaved)

        if leadingSilenceSeconds > 0 {
            let silence = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(sampleRate))!
            silence.frameLength = AVAudioFrameCount(sampleRate)
            for _ in 0..<leadingSilenceSeconds {
                try file.write(from: silence)
            }
        }
        if signalSeconds > 0 {
            let signal = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(sampleRate))!
            signal.frameLength = AVAudioFrameCount(sampleRate)
            let channel = signal.floatChannelData![0]
            for i in 0..<Int(sampleRate) {
                channel[i] = Float(sin(Double(i) * 0.08)) * 0.4 + Float.random(in: -0.2...0.2)
            }
            for _ in 0..<signalSeconds {
                try file.write(from: signal)
            }
        }
    }

    func testLoadsRawADTSAACWithLeadingSilenceAtTrueDuration() async throws {
        let root = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("note.aac")
        try writeRawADTSAAC(to: url, leadingSilenceSeconds: 1, signalSeconds: 10)

        let player = NoteAudioPlayer()
        player.volume = 0
        await player.load(url)

        XCTAssertTrue(player.isReady)
        XCTAssertFalse(player.failed)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.duration, 11.0, accuracy: 0.15)

        player.stop()
        XCTAssertFalse(player.isReady)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.position, 0)
    }

    func testSeeksAccuratelyNearEndOfRawADTSAACAndResetsOnCompletion() async throws {
        let root = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("seek.aac")
        try writeRawADTSAAC(to: url, leadingSilenceSeconds: 1, signalSeconds: 10)

        var beforePlayCalls = 0
        let player = NoteAudioPlayer {
            beforePlayCalls += 1
        }
        player.volume = 0
        await player.load(url)
        XCTAssertTrue(player.isReady)

        // Seek to 0.6s before the true end (11.0s). With AVAudioPlayer on ADTS,
        // byte-offset estimation jumps far earlier and does not finish anywhere near 0.6s.
        player.seek(to: max(0, player.duration - 0.6), play: true)
        XCTAssertEqual(beforePlayCalls, 1)
        XCTAssertTrue(player.isPlaying)

        let deadline = Date().addingTimeInterval(5.0)
        while player.isPlaying && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(player.isPlaying, "Playback should finish promptly after seeking near the end of ADTS .aac")
        XCTAssertEqual(player.position, 0, accuracy: 0.05)
        player.stop()
    }

    func testMissingAndCorruptFileMarksFailed() async throws {
        let root = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let player = NoteAudioPlayer()
        await player.load(root.appendingPathComponent("missing.aac"))
        XCTAssertTrue(player.failed)
        XCTAssertFalse(player.isReady)
        XCTAssertEqual(player.duration, 0)

        let corrupt = root.appendingPathComponent("corrupt.aac")
        try Data("not audio bytes".utf8).write(to: corrupt)
        await player.load(corrupt)
        XCTAssertTrue(player.failed)
        XCTAssertFalse(player.isReady)
        XCTAssertEqual(player.duration, 0)
    }

    func testPausePreservesLoadedState() async throws {
        let root = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("pause.aac")
        try writeRawADTSAAC(to: url, leadingSilenceSeconds: 1, signalSeconds: 3)

        let player = NoteAudioPlayer()
        player.volume = 0
        await player.load(url)
        player.play()
        XCTAssertTrue(player.isPlaying)

        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.isReady)
        XCTAssertEqual(player.duration, 4.0, accuracy: 0.15)
        player.stop()
    }
}
