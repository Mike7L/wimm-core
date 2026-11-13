import Foundation
import AVFoundation
import Accelerate
import CryptoKit
import WimmDomain

/// Rebuildable local playback features. Originals and sidecars are never modified.
public struct AudioPlaybackAnalysis: Codable, Sendable {
    public let peaks: [Float]
    public let duration: Double
    public let silenceMap: AudioSilenceMap
}

public actor AudioAnalysisCache {
    public static let shared = AudioAnalysisCache(directory: StoragePaths.baseDirectory().appendingPathComponent("Cache/AudioPlayback"))
    private let directory: URL?
    private var memory: [String: AudioPlaybackAnalysis] = [:]
    private var order: [String] = []
    public private(set) var decodeCount = 0
    public init(directory: URL? = nil) { self.directory = directory }

    public func analysis(for url: URL, buckets requested: Int = 240,
                         configuration: AudioSilenceMap.Configuration = .init()) throws -> AudioPlaybackAnalysis {
        try Task.checkCancellation()
        let buckets = max(24, min(requested, 600))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "v1|\(url.standardizedFileURL.path)|\(attrs[.size] ?? 0)|\(attrs[.modificationDate] as? Date ?? .distantPast)|\(attrs[.systemFileNumber] ?? 0)|\(buckets)|\(configuration)"
        // Include subsecond mtime: changing audio twice in one second must invalidate the cache.
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data((identity + "|\(stamp)").utf8)).map { String(format: "%02x", $0) }.joined()
        if let result = memory[key] { touch(key); return result }
        let cached = directory?.appendingPathComponent(key + ".json")
        if let cached, let data = try? Data(contentsOf: cached),
           let result = try? JSONDecoder().decode(AudioPlaybackAnalysis.self, from: data),
           result.peaks.count == buckets, result.duration.isFinite, result.duration > 0 {
            remember(result, key: key); return result
        }
        let result = try Self.decode(url, buckets: buckets, configuration: configuration)
        try Task.checkCancellation()
        decodeCount += 1
        // Do not cache a generation read across a replacement of the source file.
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.modificationDate] as? Date == after[.modificationDate] as? Date,
              (attrs[.size] as? NSNumber) == (after[.size] as? NSNumber),
              (attrs[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber) else {
            throw CocoaError(.fileReadUnknown)
        }
        remember(result, key: key)
        if let directory, let cached {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(result), data.count <= 2 * 1024 * 1024 { try? data.write(to: cached, options: .atomic) }
            // At most 64 small result files; this cache is local and fully disposable.
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            let dated = files.compactMap { file -> (URL, Date, Int)? in
                guard file.pathExtension == "json", let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (file, info.contentModificationDate ?? .distantPast, info.fileSize ?? 0)
            }.sorted { $0.1 < $1.1 }
            var bytes = dated.reduce(0) { $0 + $1.2 }, remaining = dated.count
            for (file, _, size) in dated {
                guard remaining > 64 || bytes > 16 * 1024 * 1024 else { break }
                try? FileManager.default.removeItem(at: file)
                bytes -= size; remaining -= 1
            }
        }
        return result
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func remember(_ result: AudioPlaybackAnalysis, key: String) {
        memory[key] = result; touch(key)
        func cost(_ value: AudioPlaybackAnalysis) -> Int { value.peaks.count * 4 + value.silenceMap.silences.count * 16 }
        var bytes = memory.values.reduce(0) { $0 + cost($1) }
        while order.count > 32 || bytes > 8 * 1024 * 1024 {
            if let removed = memory.removeValue(forKey: order.removeFirst()) { bytes -= cost(removed) }
        }
    }

    private static func decode(_ url: URL, buckets: Int, configuration: AudioSilenceMap.Configuration) throws -> AudioPlaybackAnalysis {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              configuration.windowSeconds > 0, configuration.windowSeconds.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        let windowFrames = max(1, configuration.windowSeconds * file.processingFormat.sampleRate)
        guard windowFrames <= Double(UInt32.max) else { throw CocoaError(.fileReadCorruptFile) }
        let frames = AVAudioFrameCount(windowFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw CocoaError(.fileReadCorruptFile) }
        var sums = [Float](repeating: 0, count: buckets), counts = [Int](repeating: 0, count: buckets)
        var rms: [Float] = []
        var read: AVAudioFramePosition = 0
        let total = file.length
        while read < total {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(frames), total - read)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            let length = Int(buffer.frameLength)
            var energy: Float = 0
            vDSP_rmsqv(channels[0], 1, &energy, vDSP_Length(length))
            rms.append(energy)
            var offset = 0
            while offset < length {
                let absolute = read + Int64(offset)
                let bucket = min(buckets - 1, Int(Double(absolute) * Double(buckets) / Double(total)))
                let end = Int64(ceil(Double(bucket + 1) * Double(total) / Double(buckets)))
                let count = min(length - offset, max(1, Int(end - absolute)))
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    var sum: Float = 0
                    vDSP_svemg(channels[channel] + offset, 1, &sum, vDSP_Length(count))
                    sums[bucket] += sum
                    counts[bucket] += count
                }
                offset += count
            }
            read += Int64(length)
        }
        let averages = zip(sums, counts).map { $1 > 0 ? $0 / Float($1) : 0 }
        let peak = max(averages.max() ?? 0, 0.0001)
        let normalized = averages.map { min(1, max(0, sqrt($0 / peak))) }
        let map = AudioSilenceMap.build(windowRMS: rms, windowSeconds: configuration.windowSeconds, configuration: configuration)
        return AudioPlaybackAnalysis(peaks: normalized, duration: Double(read) / file.processingFormat.sampleRate, silenceMap: map)
    }
}
