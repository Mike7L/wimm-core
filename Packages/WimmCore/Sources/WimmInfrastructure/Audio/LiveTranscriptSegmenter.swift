import Foundation

/// Where to freeze live text while recording with a file-only model (Parakeet).
///
/// Parakeet has no streaming mode for Ultra, but it reads 15 s of audio in ~0.1 s, so the live
/// preview simply re-reads the audio since the last freeze every second. To keep that window
/// short (and inside the model's 15 s input) the head of the window is frozen at a pause:
/// cutting in silence never splits a word, so the frozen text is final. FluidAudio's own
/// sliding-window manager only emits every 11 s with ~13 s of lag, which is no live preview.
public struct LiveTranscriptSegmenter: Sendable {
    public var sampleRate: Double = 16_000
    /// Never freeze less than this: short heads lose the context that makes Parakeet accurate.
    public var minHeadSeconds: Double = 6
    /// Past this, freeze at the quietest moment even without a real pause.
    public var forceHeadSeconds: Double = 13
    /// A pause this close to the end may just be a breath before the next word.
    public var tailGuardSeconds: Double = 0.8
    public var pauseSeconds: Double = 0.35
    /// Below this frame RMS (≈ −54 dBFS) audio counts as quiet whatever the recording's level.
    public var absoluteQuietRMS: Float = 0.002
    /// Nothing in the window ever reached this (≈ −60 dBFS): no point asking the model.
    public var silentPeakRMS: Float = 0.001

    static let frameSeconds: Double = 0.05

    public init() {}

    /// The sample index to freeze at, or nil to keep the whole window live.
    public func cutPoint(_ samples: [Float]) -> Int? {
        let frameLength = Int(sampleRate * Self.frameSeconds)
        let duration = Double(samples.count) / sampleRate
        guard frameLength > 0, duration >= minHeadSeconds else { return nil }

        let rms = Self.frameRMS(samples, frameLength: frameLength)
        let firstFrame = Int(minHeadSeconds / Self.frameSeconds)
        let lastFrame = rms.count - Int(tailGuardSeconds / Self.frameSeconds)
        guard lastFrame > firstFrame else { return nil }

        // Quiet relative to this recording's own speech level, so a far-away voice still has pauses.
        let loud = Self.percentile(rms, 0.9)
        let threshold = max(absoluteQuietRMS, loud * 0.2)
        let pauseFrames = max(1, Int(pauseSeconds / Self.frameSeconds))

        // The latest pause wins: it freezes the most text and leaves the shortest live tail.
        var runEnd = lastFrame
        var index = lastFrame - 1
        while index >= firstFrame {
            if rms[index] < threshold {
                if runEnd - index >= pauseFrames {
                    let middle = (index + runEnd) / 2
                    return middle * frameLength
                }
            } else {
                runEnd = index
            }
            index -= 1
        }

        guard duration >= forceHeadSeconds else { return nil }
        let quietest = (firstFrame..<lastFrame).min { rms[$0] < rms[$1] } ?? lastFrame
        return quietest * frameLength + frameLength / 2
    }

    /// True when the model would only hallucinate here.
    public func isSilent(_ samples: [Float]) -> Bool {
        let frameLength = Int(sampleRate * Self.frameSeconds)
        guard frameLength > 0 else { return true }
        return (Self.frameRMS(samples, frameLength: frameLength).max() ?? 0) < silentPeakRMS
    }

    static func frameRMS(_ samples: [Float], frameLength: Int) -> [Float] {
        stride(from: 0, to: samples.count, by: frameLength).map { start in
            let end = min(start + frameLength, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(max(1, end - start))).squareRoot()
        }
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
