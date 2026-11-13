import AVFoundation
import Foundation
import WimmDomain
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// Live text from Parakeet while recording: re-reads the audio since the last pause every
/// refresh and freezes the head at a pause (`LiveTranscriptSegmenter`). The frozen text is what
/// a file run over the same stretch would say; only the tail after the last pause is still
/// changing. Each refresh costs one model call over ≤ ~15 s of audio (~0.1 s on M1 / A16).
public actor ParakeetLiveTranscriber {
    private let adapter: ParakeetTranscriptionAdapter
    private let segmenter: LiveTranscriptSegmenter
    private var frozen: [String] = []
    private var pending: [Float] = []
    private var tail = ""
    private var lastPublished = ""
    private var liveSession: UUID?

    /// A model call needs at least 300 ms; shorter tails just wait for more audio.
    private static let minimumSamples = 8_000

    public init(modelIdentifier: String = ParakeetModel.ultra, language: String = "Auto",
                segmenter: LiveTranscriptSegmenter = LiveTranscriptSegmenter()) {
        self.adapter = ParakeetTranscriptionAdapter(modelIdentifier: modelIdentifier, language: language)
        self.segmenter = segmenter
    }

    /// Loads (and on first use downloads) the model. Throws when Parakeet is unavailable.
    public func prepare() async throws {
        if liveSession == nil { liveSession = await LocalInferenceScheduler.shared.beginLiveSession() }
        do {
            _ = try await adapter.transcribe(samples: [Float](repeating: 0, count: Self.minimumSamples))
        } catch {
            await endLiveSession()
            throw error
        }
    }

    public func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
    }

    /// The whole live text when it changed since the last call, else nil.
    public func refresh() async throws -> String? {
        if let cut = segmenter.cutPoint(pending) {
            let head = Array(pending[..<cut])
            pending.removeFirst(cut)
            let text = try await read(head)
            if !text.isEmpty { frozen.append(text) }
        }
        tail = pending.count >= Self.minimumSamples ? try await read(pending) : ""
        let text = currentText
        guard text != lastPublished else { return nil }
        lastPublished = text
        return text
    }

    /// Reads what is left and returns the final live text.
    public func finish() async throws -> String {
        do {
            let text = try await finishText()
            await endLiveSession()
            return text
        } catch {
            await endLiveSession()
            throw error
        }
    }

    private func finishText() async throws -> String {
        if pending.count >= Self.minimumSamples {
            let text = try await read(pending)
            if !text.isEmpty { frozen.append(text) }
        }
        pending.removeAll()
        tail = ""
        lastPublished = currentText
        return lastPublished
    }

    private func endLiveSession() async {
        guard let id = liveSession else { return }
        liveSession = nil
        await LocalInferenceScheduler.shared.endLiveSession(id)
    }

    deinit {
        if let id = liveSession {
            Task { await LocalInferenceScheduler.shared.endLiveSession(id) }
        }
    }

    public var currentText: String {
        (frozen + (tail.isEmpty ? [] : [tail])).joined(separator: " ")
    }

    private func read(_ samples: [Float]) async throws -> String {
        guard !segmenter.isSilent(samples) else { return "" }
        let result = try await adapter.transcribe(samples: samples)
        return result.looksLikeSilence ? "" : result.text
    }

    /// Converts a recorder buffer to the 16 kHz mono floats Parakeet reads. Safe on the audio thread.
    public nonisolated static func samples16k(from buffer: AVAudioPCMBuffer) -> [Float] {
        #if canImport(FluidAudio)
        return (try? converter.resampleBuffer(buffer)) ?? []
        #else
        return []
        #endif
    }

    #if canImport(FluidAudio)
    private static let converter = AudioConverter()
    #endif
}
