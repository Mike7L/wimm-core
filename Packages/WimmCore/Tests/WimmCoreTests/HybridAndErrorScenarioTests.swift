import XCTest
import WimmInfrastructure

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

final class HybridAndErrorScenarioTests: XCTestCase {
    func testGeminiLiveAdapterFailsOnGoAwayScenario() async throws {
        let source = TestScenarioLiveAudioSource()
        let transport = try RecordedGeminiLiveTransport(jsonObjects: [
            ["setupComplete": [:]],
            ["goAway": ["timeLeft": "1s"]]
        ])
        let adapter = GeminiLiveTranscriptionAdapter(
            apiKey: "test-key",
            modelName: "test-model",
            audioSource: source,
            transport: transport
        )

        let stream = try adapter.startStreamingCapture()
        do {
            for try await _ in stream {
                XCTFail("Expected goAway to terminate the stream with an error")
            }
            XCTFail("Expected stream to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("closing soon"))
        }
    }

    func testGeminiLiveAdapterReturnsEmptyTranscriptWhenScenarioHasNoText() async throws {
        let source = TestScenarioLiveAudioSource()
        let transport = try RecordedGeminiLiveTransport(jsonObjects: [
            ["setupComplete": [:]]
        ])
        let adapter = GeminiLiveTranscriptionAdapter(
            apiKey: "test-key",
            modelName: "test-model",
            audioSource: source,
            transport: transport
        )

        let stream = try adapter.startStreamingCapture()
        let reader = Task {
            for try await _ in stream {}
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        let result = try await adapter.stopCapture()
        _ = try await reader.value

        XCTAssertEqual(result.finalText, "")
        XCTAssertFalse(result.audioData.isEmpty)
    }

    func testRecordedBatchTranscriptionAdapterThrowsConfiguredError() async throws {
        let adapter = RecordedBatchTranscriptionAdapter(
            scenario: RecordedBatchScenario(text: nil, error: "batch failed", code: 599)
        )

        do {
            _ = try await adapter.transcribeFile(at: URL(fileURLWithPath: "/tmp/unused.wav"))
            XCTFail("Expected recorded batch adapter to throw")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 599)
            XCTAssertEqual(nsError.localizedDescription, "batch failed")
        }
    }
}

private final class TestScenarioLiveAudioSource: LiveAudioSource, @unchecked Sendable {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var task: Task<Void, Never>?

    func requestAccess() async throws {}

    func start(
        bufferHandler: @escaping LiveAudioBufferHandler,
        completionHandler: @escaping LiveAudioCompletionHandler
    ) throws -> AVAudioFormat {
        let format = self.format
        task = Task {
            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
                    completionHandler(NSError(domain: "TestScenarioLiveAudioSource", code: 1))
                    return
                }
                buffer.frameLength = 128
                let samples = buffer.floatChannelData![0]
                for index in 0..<Int(buffer.frameLength) {
                    samples[index] = Float(index % 4) / 4.0
                }
                bufferHandler(buffer)
                try await Task.sleep(nanoseconds: 20_000_000)
                completionHandler(nil)
            } catch is CancellationError {
                return
            } catch {
                completionHandler(error)
            }
        }
        return format
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

#else

final class HybridAndErrorScenarioTests: XCTestCase {
    func testPlatformPlaceholder() {
        XCTAssertTrue(true)
    }
}

#endif
