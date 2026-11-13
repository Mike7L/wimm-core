import Foundation
import WimmDomain

public struct RecordedStreamingScenario: Decodable, Sendable {
    public struct Partial: Decodable, Sendable {
        public let text: String
        public let delayMs: UInt64?
    }

    public let partials: [Partial]
    public let finalText: String?

    public init(partials: [Partial], finalText: String? = nil) {
        self.partials = partials
        self.finalText = finalText
    }
}

public struct RecordedBatchScenario: Decodable, Sendable {
    public let text: String?
    public let error: String?
    public let code: Int?

    public init(text: String? = nil, error: String? = nil, code: Int? = nil) {
        self.text = text
        self.error = error
        self.code = code
    }
}

public final class RecordedStreamingTranscriptionAdapter: TranscriptionPort, @unchecked Sendable {
    private let scenario: RecordedStreamingScenario
    private let audioDataProvider: @Sendable () throws -> Data
    private let stateQueue = DispatchQueue(label: "wimm.recorded-streaming.state")
    private var producerTask: Task<Void, Never>?
    private var latestTranscript = ""

    public init(
        scenario: RecordedStreamingScenario,
        audioDataProvider: @escaping @Sendable () throws -> Data = { Data() }
    ) {
        self.scenario = scenario
        self.audioDataProvider = audioDataProvider
    }

    public convenience init(scenarioFileURL: URL, audioFileURL: URL? = nil) throws {
        let data = try Data(contentsOf: scenarioFileURL)
        let scenario = try JSONDecoder().decode(RecordedStreamingScenario.self, from: data)
        self.init(
            scenario: scenario,
            audioDataProvider: {
                guard let audioFileURL else { return Data() }
                return try Data(contentsOf: audioFileURL)
            }
        )
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            producerTask?.cancel()
            producerTask = Task {
                do {
                    for partial in scenario.partials {
                        if Task.isCancelled { break }
                        let delay = partial.delayMs ?? 0
                        if delay > 0 {
                            try await Task.sleep(nanoseconds: delay * 1_000_000)
                        }
                        stateQueue.sync {
                            latestTranscript = partial.text
                        }
                        continuation.yield(partial.text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        producerTask?.cancel()
        producerTask = nil
        let audioData = try audioDataProvider()
        let finalText = scenario.finalText ?? stateQueue.sync { latestTranscript }
        return (audioData, finalText)
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        _ = fileURL
        return scenario.finalText ?? stateQueue.sync { latestTranscript }
    }
}

public struct RecordedBatchTranscriptionAdapter: TranscriptionPort, Sendable {
    private let scenario: RecordedBatchScenario

    public init(scenario: RecordedBatchScenario) {
        self.scenario = scenario
    }

    public init(scenarioFileURL: URL) throws {
        let data = try Data(contentsOf: scenarioFileURL)
        self.scenario = try JSONDecoder().decode(RecordedBatchScenario.self, from: data)
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        throw NSError(
            domain: "RecordedBatchTranscriptionAdapter",
            code: 2201,
            userInfo: [NSLocalizedDescriptionKey: "Streaming capture is unsupported for recorded batch adapter"]
        )
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        throw NSError(
            domain: "RecordedBatchTranscriptionAdapter",
            code: 2202,
            userInfo: [NSLocalizedDescriptionKey: "Capture stop is unsupported for recorded batch adapter"]
        )
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        _ = fileURL
        if let error = scenario.error {
            throw NSError(
                domain: "RecordedBatchTranscriptionAdapter",
                code: scenario.code ?? 2203,
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
        return scenario.text ?? ""
    }
}
