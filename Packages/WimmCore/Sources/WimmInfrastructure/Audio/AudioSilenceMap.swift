import Foundation
import AVFoundation

/// Precise, non-destructive silence map of an audio file, built from windowed
/// RMS with a threshold adapted to the recording's own noise floor.
///
/// The audio file is never modified: the map only tells playback (and later,
/// derived-audio generation) where the skippable gaps are. Detection is
/// deliberately conservative — quiet speech must never be classified as
/// silence, so thresholds stay near the noise floor and speech intervals are
/// padded before gaps are derived.
public struct AudioSilenceMap: Sendable, Equatable, Codable {
    public struct Interval: Sendable, Equatable, Codable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public var length: Double { max(0, end - start) }
        public func contains(_ time: Double) -> Bool { time >= start && time < end }
    }

    public let duration: Double
    /// Skippable silence gaps, sorted, non-overlapping.
    public let silences: [Interval]

    public init(duration: Double, silences: [Interval]) {
        self.duration = duration
        self.silences = silences
    }

    /// Where playback should jump to when `time` sits inside a silence gap.
    /// Returns `nil` when `time` is in speech or the remaining gap is too short
    /// for a seek to be worth it.
    public func skipTarget(at time: Double, minimumRemaining: Double = 0.5) -> Double? {
        guard let gap = silences.first(where: { $0.contains(time) }) else { return nil }
        let remaining = gap.end - time
        guard remaining >= minimumRemaining else { return nil }
        return min(gap.end, duration)
    }

    /// Total skippable time — what "listen without silence" saves.
    public var totalSilence: Double { silences.reduce(0) { $0 + $1.length } }
}

extension AudioSilenceMap {
    public struct Configuration: Sendable, Equatable {
        /// RMS window length; also the map's time resolution.
        public var windowSeconds: Double = 0.2
        /// Below this RMS a window can never count as speech, regardless of
        /// the adaptive threshold (guards near-digital-silence files).
        public var absoluteSilenceFloor: Float = 0.0001
        /// Multiplier over the estimated noise floor (10th percentile RMS).
        public var noiseFloorMultiplier: Float = 3
        /// Threshold cap as a fraction of the loudest window, so a uniformly
        /// loud recording is never classified as all-silence.
        public var peakFraction: Float = 0.3
        /// Speech intervals closer than this are bridged into one.
        public var bridgeGapSeconds: Double = 0.5
        /// Padding added around each speech interval before deriving gaps.
        public var speechPaddingSeconds: Double = 0.3
        /// Gaps shorter than this are not worth skipping.
        public var minimumSilenceSeconds: Double = 1.0

        public init() {}
    }

    /// Builds a map from per-window RMS values (pure; unit-testable without audio files).
    public static func build(
        windowRMS: [Float],
        windowSeconds: Double,
        configuration: Configuration = Configuration()
    ) -> AudioSilenceMap {
        let duration = Double(windowRMS.count) * windowSeconds
        guard !windowRMS.isEmpty, windowSeconds > 0 else {
            return AudioSilenceMap(duration: 0, silences: [])
        }

        let peak = windowRMS.max() ?? 0
        guard peak > configuration.absoluteSilenceFloor * 2 else {
            // Essentially a silent file: one gap covering everything.
            return AudioSilenceMap(
                duration: duration,
                silences: duration >= configuration.minimumSilenceSeconds
                    ? [Interval(start: 0, end: duration)]
                    : []
            )
        }

        let sorted = windowRMS.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let threshold = min(
            max(configuration.absoluteSilenceFloor, noiseFloor * configuration.noiseFloorMultiplier),
            peak * configuration.peakFraction
        )

        // 1. Raw speech intervals from windows above threshold.
        var speech: [Interval] = []
        var runStart: Int?
        for (index, rms) in windowRMS.enumerated() {
            if rms > threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                speech.append(Interval(
                    start: Double(start) * windowSeconds,
                    end: Double(index) * windowSeconds
                ))
                runStart = nil
            }
        }
        if let start = runStart {
            speech.append(Interval(start: Double(start) * windowSeconds, end: duration))
        }

        // 2. Pad speech and bridge near-adjacent intervals.
        let padded = speech.map { interval in
            Interval(
                start: max(0, interval.start - configuration.speechPaddingSeconds),
                end: min(duration, interval.end + configuration.speechPaddingSeconds)
            )
        }
        var merged: [Interval] = []
        for interval in padded {
            if let last = merged.last, interval.start - last.end < configuration.bridgeGapSeconds {
                merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }

        // 3. Gaps between speech intervals become the silence map.
        var silences: [Interval] = []
        var cursor: Double = 0
        for interval in merged {
            if interval.start - cursor >= configuration.minimumSilenceSeconds {
                silences.append(Interval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if duration - cursor >= configuration.minimumSilenceSeconds {
            silences.append(Interval(start: cursor, end: duration))
        }

        return AudioSilenceMap(duration: duration, silences: silences)
    }
}

extension AudioSilenceMap {
    /// Decodes the file and builds its map synchronously (no caching).
    /// Fail-open: `nil` when the file cannot be decoded.
    public static func analyze(
        url: URL,
        configuration: Configuration = Configuration()
    ) -> AudioSilenceMap? {
        guard let rms = windowRMS(of: url, windowSeconds: configuration.windowSeconds) else {
            return nil
        }
        return build(windowRMS: rms, windowSeconds: configuration.windowSeconds, configuration: configuration)
    }

    static func windowRMS(of url: URL, windowSeconds: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, windowSeconds > 0 else { return nil }

        let windowFrames = AVAudioFrameCount(max(1, windowSeconds * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return nil
        }

        var values: [Float] = []
        values.reserveCapacity(Int(file.length / AVAudioFramePosition(windowFrames)) + 1)
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: windowFrames)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            guard let rms = AudioEnergyProbe.rms(of: buffer) else { return nil }
            values.append(rms)
        }
        return values.isEmpty ? nil : values
    }
}

/// Decodes files into silence maps, caching by (path, size, mtime) like
/// `AudioWaveformAnalyzer`. Fail-open: an undecodable file yields `nil`, and
/// callers keep their existing behavior (playback just doesn't skip).
public actor AudioSilenceAnalyzer {
    public static let shared = AudioSilenceAnalyzer()

    private let configuration: AudioSilenceMap.Configuration
    public init(configuration: AudioSilenceMap.Configuration = .init()) { self.configuration = configuration }
    public func silenceMap(for url: URL) async -> AudioSilenceMap? {
        try? await AudioAnalysisCache.shared.analysis(for: url, configuration: configuration).silenceMap
    }
}
