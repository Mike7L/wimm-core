import CryptoKit
import Foundation
import WimmDomain
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
import AVFoundation
import CoreML
#endif

/// Personal biometric data, kept outside sidecars and never bundled or synced.
/// Automatic matches and label corrections never train this profile.
public struct OwnerVoiceProfile: Codable, Sendable {
    public static let model = "wespeaker-offline-256-v1"
    public let schema: Int
    public let model: String
    public let embedding: [Double]
    public let threshold: Double
    public let source: String
    public let embeddingWeightsSHA256: String
    public let fbankWeightsSHA256: String

    public var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    public var isValid: Bool {
        schema == 1 && model == Self.model && embedding.count == 256 &&
        embedding.allSatisfy(\.isFinite) && threshold.isFinite && (0.3...0.95).contains(threshold) &&
        embeddingWeightsSHA256.count == 64 && fbankWeightsSHA256.count == 64 &&
        abs(embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.01
    }

    public static var url: URL {
        StoragePaths.baseDirectory().appendingPathComponent("VoiceProfile/owner.json")
    }

    public static func load() -> Self? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }

    public static func install(from file: URL) throws {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum OwnerVoiceVerifier {
    public struct Match: Sendable {
        public let isOwner: Bool
        public let score: Double
        public let profileID: String
    }

    /// Conservative recording-level vote. Scores are cosine similarities, not probabilities.
    public static func accepted(scores: [Double], threshold: Double) -> Bool {
        guard scores.count >= 2, scores.allSatisfy(\.isFinite) else { return false }
        return scores.filter { $0 >= threshold }.count * 5 >= scores.count * 4
    }

    public static func match(file: URL, spans: [SpeakerTurns.Span]) async throws -> Match? {
        guard let profile = OwnerVoiceProfile.load() else { return nil }
        #if canImport(FluidAudio)
        return try await LocalInferenceScheduler.shared.withPermit(priority: .background) {
            try Task.checkCancellation()
            return try infer(file: file, spans: spans, profile: profile)
        }
        #else
        return nil
        #endif
    }

    #if canImport(FluidAudio)
    private static func infer(file: URL, spans: [SpeakerTurns.Span], profile: OwnerVoiceProfile) throws -> Match? {
        var windows: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            var start = span.start + 0.15
            let end = span.end - 0.15
            while end - start >= 2 {
                let stop = min(start + 6, end)
                windows.append((start, stop))
                start = stop
            }
        }
        // Spread evidence across the recording; the first 30 seconds must not
        // decide the identity of an entire long recording.
        if windows.count > 5 {
            let all = windows
            windows = (0..<5).map { all[$0 * (all.count - 1) / 4] }
        }
        guard windows.count >= 2, windows.reduce(0, { $0 + $1.1 - $1.0 }) >= 6 else { return nil }
        let directory = OfflineDiarizerModels.defaultModelsDirectory()
        let candidates = ["speaker-diarization", "speaker-diarization-coreml/offline", "speaker-diarization-coreml"]
        guard let modelDirectory = candidates.map({ directory.appendingPathComponent($0) }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("FBank.mlmodelc").path) &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Embedding.mlmodelc").path)
        }) else { return nil }
        func digest(_ name: String) throws -> String {
            SHA256.hash(data: try Data(contentsOf: modelDirectory.appendingPathComponent("\(name).mlmodelc/weights/weight.bin"),
                                       options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        }
        guard try digest("Embedding") == profile.embeddingWeightsSHA256,
              try digest("FBank") == profile.fbankWeightsSHA256 else { return nil }
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        let ane = MLModelConfiguration(); ane.computeUnits = .cpuAndNeuralEngine
        let fbank = try MLModel(contentsOf: modelDirectory.appendingPathComponent("FBank.mlmodelc"), configuration: cpu)
        let encoder = try MLModel(contentsOf: modelDirectory.appendingPathComponent("Embedding.mlmodelc"), configuration: ane)
        guard let audioShape = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape,
              let weightShape = encoder.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint?.shape,
              audioShape.reduce(1, { $0 * $1.intValue }) == 160000 else { return nil }
        let source = try AVAudioFile(forReading: file)
        let format = source.processingFormat
        let converter = AudioConverter()
        var scores: [Double] = []
        for (start, end) in windows {
            try Task.checkCancellation()
            let score: Double = try autoreleasepool {
                source.framePosition = AVAudioFramePosition(start * format.sampleRate)
                let capacity = AVAudioFrameCount((end-start) * format.sampleRate)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw CocoaError(.fileReadUnknown)
                }
                try source.read(into: buffer, frameCount: capacity)
                let samples = try converter.resampleBuffer(buffer)
                guard !samples.isEmpty else { throw CocoaError(.fileReadUnknown) }
                let audio = try MLMultiArray(shape: audioShape, dataType: .float32)
                let pointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
                for index in 0..<audio.count { pointer[index] = samples[index % samples.count] }
                let result = try fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
                guard let features = result.featureValue(for: "fbank_features")?.multiArrayValue,
                      features.shape.count == 4, features.dataType == .float32 else { throw CocoaError(.fileReadCorruptFile) }
                recenter(features, audio: pointer, count: audio.count)
                let weights = try MLMultiArray(shape: weightShape, dataType: .float32)
                let weightPointer = weights.dataPointer.assumingMemoryBound(to: Float.self)
                for index in 0..<weights.count { weightPointer[index] = 1 }
                let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "fbank_features": features, "weights": weights]))
                guard let vector = output.featureValue(for: "embedding")?.multiArrayValue, vector.count == 256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let values = (0..<vector.count).map { vector[$0].doubleValue }
                let norm = sqrt(values.reduce(0) { $0 + $1*$1 })
                guard norm > 0, norm.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                return zip(values, profile.embedding).reduce(0) { $0 + $1.0 / norm * $1.1 }
            }
            scores.append(score)
        }
        return Match(isOwner: accepted(scores: scores, threshold: profile.threshold),
                     score: scores.sorted()[scores.count / 2], profileID: profile.id)
    }

    /// Same digital-silence correction as FluidAudio's offline embedSpan path.
    private static func recenter(_ features: MLMultiArray, audio: UnsafePointer<Float>, count: Int) {
        var prefix = [Int](repeating: 0, count: count+1)
        for index in 0..<count { prefix[index+1] = prefix[index] + (audio[index] != 0 ? 1 : 0) }
        let frames = features.shape[3].intValue
        let voiced = (0..<frames).filter { frame in
            let start = min(frame*160, count), end = min(frame*160+400, count)
            return prefix[end] > prefix[start]
        }
        guard !voiced.isEmpty, voiced.count < frames else { return }
        let pointer = features.dataPointer.assumingMemoryBound(to: Float.self)
        let bandStride = features.strides[2].intValue, frameStride = features.strides[3].intValue
        for band in 0..<features.shape[2].intValue {
            let row = pointer + band*bandStride
            let mean = voiced.reduce(Float(0)) { $0 + row[$1*frameStride] } / Float(voiced.count)
            for frame in 0..<frames { row[frame*frameStride] -= mean }
        }
    }
    #endif
}
