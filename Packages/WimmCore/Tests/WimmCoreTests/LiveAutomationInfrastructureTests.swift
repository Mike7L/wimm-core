import XCTest
import WimmInfrastructure

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

final class LiveAutomationInfrastructureTests: XCTestCase {
    func testRecordedGeminiLiveTransportReplaysMessagesAndCapturesSentPayloads() async throws {
        let transport = try RecordedGeminiLiveTransport(jsonObjects: [
            ["setupComplete": [:]],
            ["inputTranscription": ["text": "partial"]]
        ])

        let stream = try await transport.connect(request: URLRequest(url: URL(string: "https://example.com")!))
        try await transport.send(Data("client".utf8))

        var payloads: [[String: Any]] = []
        for try await data in stream {
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            payloads.append(json)
        }

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[1]["inputTranscription"] as? [String: String], ["text": "partial"])
        XCTAssertEqual(transport.sentPayloadsSnapshot, [Data("client".utf8)])
    }

    func testFixtureAudioSourceStreamsBuffersAndCompletes() async throws {
        let fileURL = try makeFixtureWAV(frameCount: 1024)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let source = FixtureAudioSource(
            fileURL: fileURL,
            chunkFrameCount: 256,
            interChunkDelayNanoseconds: 0
        )

        let completion = expectation(description: "fixture completed")
        let collector = FrameLengthCollector()

        let format = try source.start(
            bufferHandler: { buffer in
                Task {
                    await collector.append(buffer.frameLength)
                }
            },
            completionHandler: { error in
                XCTAssertNil(error)
                completion.fulfill()
            }
        )

        await fulfillment(of: [completion], timeout: 1.0)
        let frameLengths = try await waitForFrameLengths(in: collector, expectedTotal: 1024)

        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(frameLengths.reduce(0, +), 1024)
        XCTAssertGreaterThan(frameLengths.count, 1)
    }

    func testGeminiLiveAdapterUsesInjectedAudioSourceAndRecordedTransport() async throws {
        let source = TestLiveAudioSource()
        let transport = try RecordedGeminiLiveTransport(jsonObjects: [
            ["setupComplete": [:]],
            ["inputTranscription": ["text": "hello world"]]
        ])
        let adapter = GeminiLiveTranscriptionAdapter(
            apiKey: "test-key",
            modelName: "test-model",
            audioSource: source,
            transport: transport
        )

        let stream = try adapter.startStreamingCapture()
        let collector = PartialCollector()
        let reader = Task {
            for try await text in stream {
                await collector.append(text)
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        let result = try await adapter.stopCapture()
        _ = try await reader.value
        let partials = await collector.snapshot()

        XCTAssertEqual(result.finalText, "hello world")
        XCTAssertFalse(result.audioData.isEmpty)
        XCTAssertEqual(partials.last, "hello world")

        let sentPayloads = transport.sentPayloadsSnapshot
        XCTAssertGreaterThanOrEqual(sentPayloads.count, 2)

        let sentJSON = try sentPayloads.map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertTrue(sentJSON.contains { $0["setup"] != nil })
        XCTAssertTrue(sentJSON.contains {
            (($0["realtimeInput"] as? [String: Any])?["audioStreamEnd"] as? Bool) == true
        })
    }

    private func makeFixtureWAV(frameCount: AVAudioFrameCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-audio-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = Float(index % 16) / 16.0
        }

        try file.write(from: buffer)
        return url
    }

    private func waitForFrameLengths(
        in collector: FrameLengthCollector,
        expectedTotal: AVAudioFrameCount
    ) async throws -> [AVAudioFrameCount] {
        for _ in 0..<20 {
            let snapshot = await collector.snapshot()
            if snapshot.reduce(0, +) == expectedTotal {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await collector.snapshot()
    }
}

private final class TestLiveAudioSource: LiveAudioSource, @unchecked Sendable {
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
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else {
                    completionHandler(NSError(domain: "TestLiveAudioSource", code: 1))
                    return
                }
                buffer.frameLength = 256
                let samples = buffer.floatChannelData![0]
                for index in 0..<Int(buffer.frameLength) {
                    samples[index] = Float(index % 8) / 8.0
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

private actor FrameLengthCollector {
    private var frameLengths: [AVAudioFrameCount] = []

    func append(_ value: AVAudioFrameCount) {
        frameLengths.append(value)
    }

    func snapshot() -> [AVAudioFrameCount] {
        frameLengths
    }
}

private actor PartialCollector {
    private var partials: [String] = []

    func append(_ value: String) {
        partials.append(value)
    }

    func snapshot() -> [String] {
        partials
    }
}

#else

final class LiveAutomationInfrastructureTests: XCTestCase {
    func testPlatformPlaceholder() {
        XCTAssertTrue(true)
    }
}

#endif
