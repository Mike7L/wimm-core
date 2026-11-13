import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Builds a PCM-16 WAV file from raw float audio buffers.
///
/// Extracted from NativeSpeechAdapter to enable independent testing
/// and reuse across audio pipeline stages.
struct WAVBuilder {
    private(set) var pcmData = Data()
    private(set) var sampleRate: Double = 44_100
    private(set) var channels: UInt16 = 1

    mutating func configure(sampleRate: Double, channels: UInt16) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    mutating func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var local = Data(capacity: frameCount * channelCount * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            for ch in 0..<channelCount {
                let sample = channelData[ch][frame]
                var intSample = Int16((max(-1.0, min(1.0, sample))) * Float(Int16.max))
                withUnsafeBytes(of: &intSample) { local.append(contentsOf: $0) }
            }
        }
        pcmData.append(local)
    }

    mutating func reset() {
        pcmData = Data()
    }

    /// Builds the complete WAV file from accumulated PCM data.
    func build() -> Data {
        WAVBuilder.makeWAV(fromPCM16: pcmData, sampleRate: sampleRate, channels: channels)
    }

    // MARK: - Static builder

    static func makeWAV(fromPCM16 pcm: Data, sampleRate: Double, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var wav = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }

        wav.append("RIFF".data(using: .ascii)!)
        appendLE(chunkSize)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16))        // subchunk1Size
        appendLE(UInt16(1))         // audioFormat = PCM
        appendLE(channels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        wav.append("data".data(using: .ascii)!)
        appendLE(dataSize)
        wav.append(pcm)
        return wav
    }
}

#endif
