import XCTest
import AVFoundation
@testable import WimmDocumentUI
import WimmInfrastructure

@MainActor
final class CaptureMicrophoneRetryTests: XCTestCase {
    private let formatRefusal = NSError(domain: "com.apple.coreaudio.avfaudio", code: 560_226_676)

    func testFormatRefusalIsRecognizedAndExplained() {
        XCTAssertEqual(CaptureSession.fourCC(560_226_676), "!dat")
        XCTAssertNil(CaptureSession.fourCC(-50))
        XCTAssertTrue(CaptureSession.isFormatRefusal(formatRefusal))
        XCTAssertTrue(CaptureSession.isFormatRefusal(NSError(domain: "MicrophoneAudioSource", code: 2003)))
        XCTAssertFalse(CaptureSession.isFormatRefusal(NSError(domain: "MicrophoneAudioSource", code: 2001)))

        let message = CaptureSession.microphoneMessage(for: formatRefusal, device: "Test Headset")
        XCTAssertTrue(message.contains("«Test Headset»"))
        XCTAssertFalse(message.contains("560226676"))
        XCTAssertFalse(CaptureSession.microphoneMessage(for: formatRefusal, device: nil).contains("  "))
        XCTAssertTrue(CaptureSession.describe(formatRefusal).contains("'!dat'"))
    }

    func testStartRetriesWhileTheInputRefusesItsFormat() async {
        let attempts = AttemptCounter(failures: 2, error: formatRefusal)
        let capture = CaptureSession(sourceFactory: { RetryTestMicrophone(counter: attempts) },
                                     liveFactory: { RetryTestASR() })
        capture.allowsNoteCardAnalysis = false
        defer { capture.finishForTermination() }

        await capture.start()

        XCTAssertEqual(capture.phase, .recording)
        XCTAssertNil(capture.errorMessage)
        XCTAssertEqual(attempts.count, 3)
    }

    func testStartReportsAReadableMessageAfterTheWindow() async {
        let attempts = AttemptCounter(failures: .max, error: formatRefusal)
        let capture = CaptureSession(sourceFactory: { RetryTestMicrophone(counter: attempts) },
                                     liveFactory: { RetryTestASR() })
        capture.allowsNoteCardAnalysis = false
        capture.microphoneRetryWindow = .milliseconds(300)
        defer { capture.finishForTermination() }

        await capture.start()

        XCTAssertEqual(capture.phase, .idle)
        XCTAssertGreaterThan(attempts.count, 1)
        XCTAssertTrue(capture.errorMessage?.contains("не принял формат") == true, capture.errorMessage ?? "nil")
    }

    /// A headset mic at 8/16/24 kHz used to leave a 0-byte .aac: the encoder
    /// refuses 96 kbps there. The file is written at 48 kHz instead.
    func testHeadsetSampleRatesStillWriteAudio() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for rate in [8_000.0, 16_000, 24_000, 48_000] {
            let url = dir.appendingPathComponent("\(Int(rate)).aac")
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let sink = try AudioFileSink(url: url, format: format)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for chunk in 0..<Int(rate / 1024) * 2 {
                for i in 0..<1024 { buffer.floatChannelData![0][i] = sin(Float(chunk * 1024 + i) / 8) * 0.3 }
                sink.write(buffer)
            }
            sink.finish()
            let read = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(read.fileFormat.sampleRate, 44_000, "\(rate)")
            XCTAssertGreaterThan(Double(read.length) / read.fileFormat.sampleRate, 1.5, "\(rate) Hz wrote too little")
        }
        XCTAssertEqual(AudioFileSink.fileSampleRate(forInput: 24_000), 48_000)
        XCTAssertEqual(AudioFileSink.fileSampleRate(forInput: 44_100), 44_100)
    }

    func testLevelMeterCountsTimeWithoutBuffers() throws {
        let meter = LevelMeter()
        meter.resetSilence()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(meter.secondsWithoutBuffers, 0.04)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        meter.update(buffer)
        XCTAssertLessThan(meter.secondsWithoutBuffers, 0.04)
    }
}

private final class AttemptCounter: @unchecked Sendable {
    let failures: Int
    let error: Error
    private(set) var count = 0
    init(failures: Int, error: Error) { self.failures = failures; self.error = error }
    func next() -> Bool { count += 1; return count > failures }
}

private struct RetryTestMicrophone: LiveAudioSource {
    let counter: AttemptCounter
    func requestAccess() async throws {}
    func start(bufferHandler: @escaping LiveAudioBufferHandler,
               completionHandler: @escaping LiveAudioCompletionHandler) throws -> AVAudioFormat {
        guard counter.next() else { throw counter.error }
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }
    func stop() {}
}

private actor RetryTestASR: CaptureLiveTranscribing {
    func prepare() async throws {}
    func append(_ samples: [Float]) {}
    func refresh() async throws -> String? { nil }
    func finish() async throws -> String { "" }
}
