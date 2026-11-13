import Foundation
import WimmDomain

public final class HybridGeminiTranscriptionAdapter: TranscriptionPort, @unchecked Sendable {
    private let streaming: TranscriptionPort
    private let batch: any FileTranscriptionPort

    public init(
        apiKey: String,
        modelName: String = DefaultModels.gemini,
        streaming: TranscriptionPort = NativeSpeechAdapter(),
        batch: (any FileTranscriptionPort)? = nil
    ) {
        self.streaming = streaming
        self.batch = batch ?? GeminiTranscriptionAdapter(apiKey: apiKey, modelName: modelName)
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        try streaming.startStreamingCapture()
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        let (audioData, nativeText) = try await streaming.stopCapture()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-hybrid-\(UUID().uuidString).wav")

        do {
            try audioData.write(to: tempURL, options: .atomic)
            let geminiText = try await batch.transcribeFile(at: tempURL)
            let trimmedGemini = geminiText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGemini.isEmpty {
                return (audioData, geminiText)
            }
        } catch {
            let trimmedNative = nativeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNative.isEmpty {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }

        try? FileManager.default.removeItem(at: tempURL)
        return (audioData, nativeText)
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        try await batch.transcribeFile(at: fileURL)
    }
}
