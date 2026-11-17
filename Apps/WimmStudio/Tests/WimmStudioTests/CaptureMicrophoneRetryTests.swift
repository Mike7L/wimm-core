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
