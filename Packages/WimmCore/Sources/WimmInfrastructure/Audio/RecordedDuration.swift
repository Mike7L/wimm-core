import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The duration a finished recording's sidecar states. A recorder's clock
/// counts from start to stop, but the file can stop growing before that
/// (an audio interruption, an encoder error): the sidecar then promised
/// minutes that were never saved, and every reader blamed the transcript.
/// The finalized file is the truth of what was saved.
public enum RecordedDuration {
    public struct Verdict: Equatable, Sendable {
        /// What the sidecar should state.
        public let seconds: TimeInterval
        /// Clock seconds the file does not hold (0 when they agree).
        public let unsavedSeconds: TimeInterval
    }

    /// A gap below this is container rounding or stop latency, not lost audio.
    public static let toleratedGap: TimeInterval = 2

    /// Pure: the file's length when it is known, else the clock's.
    public static func reconcile(clock: TimeInterval, file: TimeInterval?) -> Verdict {
        guard let file, file.isFinite, file > 0 else {
            return Verdict(seconds: max(0, clock), unsavedSeconds: 0)
        }
        let gap = clock - file
        return Verdict(seconds: file, unsavedSeconds: gap > toleratedGap ? gap : 0)
    }

    /// Length of a finalized audio file; nil when it cannot be read.
    /// Uses precise timing so headerless VBR streams (such as raw ADTS `.aac`)
    /// report their actual frame duration rather than a bitrate estimate from
    /// the start of the file.
    public static func fileSeconds(of url: URL) async -> TimeInterval? {
#if canImport(AVFoundation)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
#else
        return nil
#endif
    }
}
