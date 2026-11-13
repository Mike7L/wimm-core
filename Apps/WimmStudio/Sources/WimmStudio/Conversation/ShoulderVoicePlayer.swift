@preconcurrency import AVFoundation
import Foundation
import WimmDomain
import WimmInfrastructure

extension ShoulderSpeaker {
    static let angelVoiceKey = "WimmStudio.shouldersAngelVoice"
    static let demonVoiceKey = "WimmStudio.shouldersDemonVoice"
    static let speedMultiplierKey = "WimmStudio.shouldersSpeedMultiplier"
    static let autoRecordAfterTurnKey = "WimmStudio.shouldersAutoRecordAfterTurn"

    static let availableFemaleVoices = ["F1", "F2", "F3", "F4", "F5"]
    static let availableMaleVoices = ["M1", "M2", "M3", "M4", "M5"]

    /// Supertonic-3 voices (default picked by ear on 2026-11-03: light female angel F4, low male demon M5),
    /// configurable in UserDefaults (`WimmStudio.shouldersAngelVoice` / `WimmStudio.shouldersDemonVoice`).
    var neuralVoice: NeuralSpeech.Voice {
        if self == .angel {
            let v = UserDefaults.standard.string(forKey: Self.angelVoiceKey) ?? "F4"
            return .init(Self.availableFemaleVoices.contains(v) ? v : "F4")
        } else {
            let v = UserDefaults.standard.string(forKey: Self.demonVoiceKey) ?? "M5"
            return .init(Self.availableMaleVoices.contains(v) ? v : "M5")
        }
    }

    /// +10% quicker than before (was 1.05 / 1.10 -> 1.16 / 1.21), scaled by optional multiplier.
    var neuralSpeed: Float {
        let base: Float = self == .angel ? 1.16 : 1.21
        let rawMult = UserDefaults.standard.object(forKey: Self.speedMultiplierKey) as? Double ?? 1.0
        let mult = Float(max(0.75, min(1.6, rawMult)))
        return base * mult
    }
}

/// Reads angel-and-demon lines in the on-device Supertonic-3 voices. Lines are
/// synthesized one after another as they arrive, so the next one is ready while
/// the current one plays; the first sound comes about half a second after a line.
@MainActor
final class ShoulderVoicePlayer {
    /// A line started playing (its index in the dialogue).
    var onLineStarted: ((Int) -> Void)?
    /// Everything queued has been played.
    var onIdle: (() -> Void)?
    /// The queue could not synthesize or play a line. Hosts may show the text.
    var onFailure: (() -> Void)?
    /// The model and both voices are loaded; until then the system voice reads.
    private(set) var isReady = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: NeuralSpeech.sampleRate, channels: 1)!
    private var preparing: Task<Void, Never>?
    /// Bumped by `stop()`; work from an older generation is dropped.
    private var generation = 0
    /// The last line's synthesis, which the next one waits for to keep the order.
    private var chain: Task<Void, Never>?
    private var synthesizing = 0
    /// When the model last produced audio here; see `warmUp()`.
    private var lastSynthesis = Date.distantPast
    /// Quiet time after which the next line is expected to be slow.
    private static let coldAfter: TimeInterval = 120
    /// Lines on the player's timeline, in order, with the frame each one starts at.
    /// The playing line is read from the player's clock, not from buffer callbacks:
    /// `.dataPlayedBack` arrived late or never, and the window kept showing the
    /// angel while the demon was already talking (2026-11-03).
    private var timeline: [(index: Int, start: AVAudioFramePosition)] = []
    /// Where the last scheduled line ends, in player frames.
    private var cursor: AVAudioFramePosition = 0
    private var announced: Int?
    private var ticker: Timer?
    /// Breath between two lines.
    private static let pause = 0.12

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Loads the model in the background; the first time it downloads and compiles (~40 s).
    func prepare() {
        guard !isReady, preparing == nil else { return }
        let allVoices = (ShoulderSpeaker.availableFemaleVoices + ShoulderSpeaker.availableMaleVoices).map { NeuralSpeech.Voice($0) }
        preparing = Task { [weak self] in
            do {
                try await NeuralSpeech.shared.prepare(voices: allVoices)
                self?.isReady = true
                self?.lastSynthesis = Date()
            } catch {
                log("[ShoulderVoice] Supertonic-3 unavailable, system voice stays: \(error.localizedDescription)")
                self?.preparing = nil
            }
        }
    }

    /// Runs a throwaway phrase when the model has been quiet for a while. After 47 minutes
    /// of silence the first line took 13.9 s instead of 0.5 s (measured 2026-11-10): the
    /// system had unloaded the model. Call it when a reply is on its way, not on a timer.
    func warmUp() {
        guard isReady, synthesizing == 0, Date().timeIntervalSince(lastSynthesis) > Self.coldAfter else { return }
        lastSynthesis = Date()
        let serial = generation
        let previous = chain
        // In the chain, so a line that arrives meanwhile waits instead of competing.
        chain = Task { [weak self] in
            await previous?.value
            let started = Date()
            // About as long as a real line: a one-word phrase may not wake the same model shapes (my guess).
            _ = try? await NeuralSpeech.shared.synthesize(
                "Проверка голоса перед разговором, чтобы первая реплика не ждала.",
                voice: ShoulderSpeaker.angel.neuralVoice, speed: ShoulderSpeaker.angel.neuralSpeed)
            log(String(format: "[ShoulderVoice] warm-up after quiet: %.2fs", Date().timeIntervalSince(started)))
            guard let self, self.generation == serial else { return }
            self.lastSynthesis = Date()
        }
    }

    func enqueue(_ text: String, speaker: ShoulderSpeaker, index: Int,
                 voice: NeuralSpeech.Voice? = nil, speed: Float? = nil) {
        let serial = generation
        let previous = chain
        synthesizing += 1
        chain = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == serial, !Task.isCancelled else { return }
            let started = Date()
            var samples: [Float] = []
            do {
                samples = try await NeuralSpeech.shared.synthesize(text, voice: voice ?? speaker.neuralVoice, speed: speed ?? speaker.neuralSpeed)
            } catch {
                log("[ShoulderVoice] line \(index) not synthesized: \(error.localizedDescription)")
            }
            guard self.generation == serial, !Task.isCancelled else { return }
            self.synthesizing -= 1
            self.lastSynthesis = Date()
            log(String(format: "[ShoulderVoice] line %d: %.2fs for %.1fs of audio", index,
                       Date().timeIntervalSince(started), Double(samples.count) / NeuralSpeech.sampleRate))
            if samples.isEmpty { self.onFailure?(); self.finishIfIdle() }
            else { self.play(samples, index: index) }
        }
    }

    func stop() {
        generation += 1
        chain?.cancel()
        chain = nil
        synthesizing = 0
        resetTimeline()
        player.stop()
        engine.stop()
    }

    private func play(_ samples: [Float], index: Int) {
        let frames = samples.count + Int(NeuralSpeech.sampleRate * Self.pause)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else {
            onFailure?()
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        channel.initialize(repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                log("[ShoulderVoice] audio engine did not start: \(error.localizedDescription)")
                onFailure?()
                finishIfIdle()
                return
            }
        }
        // The player keeps running between turns; a new line starts now or after the last one.
        // A small margin keeps the start from landing in the already-rendered past.
        let now = player.isPlaying ? (renderedFrame(heard: false) ?? cursor) + AVAudioFramePosition(format.sampleRate * 0.05) : 0
        if !player.isPlaying { resetTimeline() }
        let start = max(cursor, now)
        timeline.append((index, start))
        cursor = start + AVAudioFramePosition(frames)
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: start, atRate: format.sampleRate))
        if !player.isPlaying { player.play() }
        startTicker()
        tick()
    }

    /// The player's rendered position; `heard` subtracts the output latency to get what is audible now.
    private func renderedFrame(heard: Bool = true) -> AVAudioFramePosition? {
        guard let node = player.lastRenderTime, node.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: node) else { return nil }
        guard heard else { return time.sampleTime }
        let latency = AVAudioFramePosition((engine.outputNode.presentationLatency * format.sampleRate).rounded())
        return time.sampleTime - latency
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard !timeline.isEmpty else { return }
        let frame = renderedFrame() ?? 0
        if frame >= cursor {
            // Everything scheduled has been heard.
            timeline = []
            announced = nil
            finishIfIdle()
            return
        }
        guard let current = timeline.last(where: { $0.start <= frame }) ?? timeline.first,
              current.index != announced else { return }
        announced = current.index
        onLineStarted?(current.index)
    }

    private func resetTimeline() {
        ticker?.invalidate()
        ticker = nil
        timeline = []
        cursor = 0
        announced = nil
    }

    private func finishIfIdle() {
        guard timeline.isEmpty, synthesizing == 0 else { return }
        ticker?.invalidate()
        ticker = nil
        onIdle?()
    }
}
