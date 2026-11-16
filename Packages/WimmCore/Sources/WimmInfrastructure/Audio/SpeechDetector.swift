import Foundation
import os
import WimmDomain
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// Tells speech from other sound in the live microphone signal.
public protocol SpeechDetecting: Sendable {
    /// 16 kHz mono samples; safe on the audio thread.
    func feed(_ samples: [Float])
    var isSpeech: Bool { get }
}

/// On-device Silero VAD (FluidAudio) over 256 ms chunks. It only drives the
/// microphone indicator: nothing is stored, sent or decided from it. When the
/// model cannot load, `isSpeech` stays false.
public final class SpeechDetector: SpeechDetecting {
    private struct State {
        var pending: [Float] = []
        var isSpeech = false
    }

    private static let chunkSize = 4096
    private let state: OSAllocatedUnfairLock<State>
    private let chunks: AsyncStream<[Float]>.Continuation
    private let worker: Task<Void, Never>

    public init() {
        let state = OSAllocatedUnfairLock(initialState: State())
        // Under load the newest audio matters, not a backlog.
        let (stream, chunks) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(4))
        self.state = state
        self.chunks = chunks
        worker = Task.detached(priority: .utility) {
            #if canImport(FluidAudio)
            let manager: VadManager
            do {
                // Silero's own 0.5, not FluidAudio's 0.85: a far or quiet voice must still count.
                // The model costs ~1 ms per chunk on the CPU; the Neural Engine adds nothing.
                manager = try await VadManager(config: VadConfig(defaultThreshold: 0.5, computeUnits: .cpuOnly))
            } catch {
                log("[Capture] speech detector unavailable: \(error.localizedDescription)")
                return
            }
            var vad = await manager.makeStreamState()
            for await chunk in stream {
                guard let result = try? await manager.processStreamingChunk(chunk, state: vad) else { continue }
                vad = result.state
                let speaking = result.state.triggered
                let changed = state.withLock { state in
                    defer { state.isSpeech = speaking }
                    return state.isSpeech != speaking
                }
                if changed {
                    log(String(format: "[Capture] speech %@ (p=%.2f)", speaking ? "on" : "off", result.probability))
                }
            }
            #endif
        }
    }

    deinit {
        chunks.finish()
        worker.cancel()
    }

    public var isSpeech: Bool { state.withLock { $0.isSpeech } }

    public func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let ready: [[Float]] = state.withLock { state in
            state.pending.append(contentsOf: samples)
            var ready: [[Float]] = []
            while state.pending.count >= Self.chunkSize {
                ready.append(Array(state.pending.prefix(Self.chunkSize)))
                state.pending.removeFirst(Self.chunkSize)
            }
            return ready
        }
        for chunk in ready { chunks.yield(chunk) }
    }
}
