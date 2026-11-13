import ArgumentParser
import Darwin
import Foundation
import WimmDomain
import WimmInfrastructure

/// Synthesizes a single line of Russian speech on-device via Supertonic-3 (`NeuralSpeech`)
/// and outputs a 16-bit PCM WAV file at 44.1 kHz mono.
/// Nothing leaves the Mac, so private mode does not apply.
struct Speak: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "Synthesize Russian speech on-device via Supertonic-3 (voices F1..F5, M1..M5) to a WAV file"
    )

    @Option(name: .long, help: "Supertonic-3 voice id: F1, F2, F3, F4, F5, M1, M2, M3, M4, M5")
    var voice: String = "F4"

    @Option(name: .long, help: "Speech speed (e.g. 1.15 for Angel, 1.21 for Demon)")
    var speed: Float = 1.15

    @Option(name: .long, help: "Output WAV file path")
    var out: String

    @Argument(help: "Russian text to synthesize")
    var text: String

    func run() async throws {
        let savedOutput = dup(STDOUT_FILENO)
        if savedOutput >= 0 {
            dup2(STDERR_FILENO, STDOUT_FILENO)
        }
        defer {
            if savedOutput >= 0 {
                dup2(savedOutput, STDOUT_FILENO)
                close(savedOutput)
            }
        }

        let normalizedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let v = NeuralSpeech.Voice(normalizedVoice)
        try await NeuralSpeech.shared.prepare(voices: [v])
        let samples = try await NeuralSpeech.shared.synthesize(text, voice: v, speed: speed)

        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        try Self.writeWAV(samples: samples, sampleRate: Int(NeuralSpeech.sampleRate), to: outURL)
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * Float(Int16.max))
        }

        let dataSize = UInt32(pcm.count * 2)
        let chunkSize = 36 + dataSize
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let audioFormat: UInt16 = 1 // PCM
        let subchunk1Size: UInt32 = 16
        let sr = UInt32(sampleRate)

        var header = Data(capacity: 44 + Int(dataSize))
        header.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: subchunk1Size.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: audioFormat.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: channels.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: sr.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { header.append(contentsOf: $0) }

        pcm.withUnsafeBufferPointer { buf in
            header.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: UInt8.self),
                count: Int(dataSize)
            ))
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try header.write(to: url, options: .atomic)
    }
}
