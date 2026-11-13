import Foundation
import AVFoundation

/// Cheap, language-agnostic acoustic energy probe.
///
/// Used as the first layer of the speech-presence gate: a recording whose RMS is
/// below the silence floor cannot contain speech, so it must never be sent to a
/// cloud transcriber (which hallucinates confident text on silence/near-silence).
///
/// Intentionally **fail-open**: if the file cannot be decoded, returns `nil` so
/// callers proceed with their existing behavior rather than dropping a recording.
public enum AudioEnergyProbe {
    /// RMS amplitude (0...1) over the first `maxSeconds` of the file
    /// (whole file when `maxSeconds <= 0`). `nil` when the file is not decodable.
    public static func rms(of url: URL, maxSeconds: Double = 30) -> Float? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0 else { return nil }

        let frameCap = maxSeconds > 0
            ? AVAudioFrameCount(min(Double(file.length), maxSeconds * format.sampleRate))
            : AVAudioFrameCount(file.length)
        guard frameCap > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCap) else {
            return nil
        }
        do {
            try file.read(into: buffer, frameCount: frameCap)
        } catch {
            return nil
        }
        return rms(of: buffer)
    }

    /// Peak windowed RMS amplitude (0...1): the maximum RMS over consecutive
    /// `windowSeconds` windows across the first `maxSeconds` of the file
    /// (whole file when `maxSeconds <= 0`). `nil` when the file is not decodable.
    ///
    /// Prefer this over `rms(of:maxSeconds:)` for silence gating: a whole-file
    /// (or long-window) mean is dragged below the floor by pauses and quiet
    /// stretches even when the recording contains clearly audible speech — a
    /// recording with even one loud window is not silent.
    ///
    /// When `earlyExitAbove` is set, returns as soon as any window reaches it
    /// (the returned value is that window's RMS, not the global peak) — cheap
    /// "is there any audible window?" checks don't need to decode the tail.
    public static func peakWindowRMS(
        of url: URL,
        windowSeconds: Double = 1.0,
        maxSeconds: Double = 0,
        earlyExitAbove: Float? = nil
    ) -> Float? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, windowSeconds > 0 else { return nil }

        let windowFrames = AVAudioFrameCount(max(1, windowSeconds * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return nil
        }
        let frameLimit: AVAudioFramePosition = maxSeconds > 0
            ? AVAudioFramePosition(min(Double(file.length), maxSeconds * format.sampleRate))
            : file.length

        var peak: Float?
        while file.framePosition < frameLimit {
            let remaining = AVAudioFrameCount(frameLimit - file.framePosition)
            do {
                try file.read(into: buffer, frameCount: min(windowFrames, remaining))
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            guard let windowRMS = rms(of: buffer) else { return nil }
            if windowRMS > (peak ?? -1) { peak = windowRMS }
            if let exit = earlyExitAbove, windowRMS >= exit { return windowRMS }
        }
        return peak
    }

    /// RMS amplitude (0...1) across channel 0 of a decoded buffer.
    public static func rms(of buffer: AVAudioPCMBuffer) -> Float? {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        if let p = buffer.floatChannelData {
            var sum: Double = 0
            for i in 0..<n { let v = Double(p[0][i]); sum += v * v }
            return Float((sum / Double(n)).squareRoot())
        }
        if let p = buffer.int16ChannelData {
            var sum: Double = 0
            for i in 0..<n { let v = Double(p[0][i]) / 32768.0; sum += v * v }
            return Float((sum / Double(n)).squareRoot())
        }
        if let p = buffer.int32ChannelData {
            var sum: Double = 0
            let scale = Double(Int32.max)
            for i in 0..<n { let v = Double(p[0][i]) / scale; sum += v * v }
            return Float((sum / Double(n)).squareRoot())
        }
        return nil
    }
}
