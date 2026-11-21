import Foundation

/// The HUD's cues, synthesized in code: no audio files in the bundle. The
/// recipes match the «Огонёк» prototype (D major pentatonic; the failure cue is
/// out of key on purpose). Pure and deterministic, so tests can check them.
enum HUDSoundSynth {
    static let sampleRate = 44_100.0
    /// Same overall level as the prototype's master gain.
    private static let master: Float = 0.7

    static func samples(for cue: HUDSound.Cue) -> [Float] {
        var mix = Mix()
        switch cue {
        case .start:
            mix.bell(Note.d5, at: 0, decay: 0.16, gain: 0.14)
            mix.bell(Note.a5, at: 0.07, decay: 0.2, gain: 0.12)
        case .stop:
            mix.bell(Note.a5, at: 0, decay: 0.13, gain: 0.11)
            mix.bell(Note.d5, at: 0.07, decay: 0.24, gain: 0.13)
            mix.thock(at: 0.07, gain: 0.14)
        case .page:
            mix.noise(at: 0, center: 1200, sweepTo: 3200, q: 1.2, decay: 0.14, gain: 0.05)
            mix.bell(Note.fSharp5, at: 0.05, decay: 0.12, gain: 0.05)
        case .saved:
            mix.bell(1480, at: 0, decay: 0.12, gain: 0.12, harmonic: 0.08, glideTo: 990)
            mix.bell(990, at: 0.12, decay: 0.14, gain: 0.035, harmonic: 0)
        case .vikHeard:
            mix.bell(Note.e5, at: 0, decay: 0.42, gain: 0.08, detuneCents: 7)
            mix.bell(Note.b5, at: 0.06, decay: 0.48, gain: 0.07, detuneCents: -7)
            mix.bell(Note.e6, at: 0.12, decay: 0.4, gain: 0.025, harmonic: 0)
        case .vikDone:
            mix.bell(Note.b5, at: 0, decay: 0.12, gain: 0.08)
            mix.bell(Note.e5, at: 0.08, decay: 0.2, gain: 0.09)
        case .fail:
            mix.bell(Note.a3, at: 0, decay: 0.12, gain: 0.2, harmonic: 0.3, wave: .triangle, lowpass: 900)
            mix.bell(Note.gSharp3, at: 0.13, decay: 0.2, gain: 0.2, harmonic: 0.3, wave: .triangle, lowpass: 900)
        case .trouble:
            mix.thock(at: 0, from: 150, to: 70, decay: 0.16, gain: 0.28)
            mix.bell(Note.d4, at: 0, decay: 0.18, gain: 0.05, wave: .triangle, lowpass: 1200)
        case .lockOn:
            mix.noise(at: 0, center: 2600)
            mix.noise(at: 0.045, center: 1800)
            mix.thock(at: 0.05, from: 240, to: 160, decay: 0.05, gain: 0.12)
        case .lockOff:
            mix.noise(at: 0, center: 1800)
            mix.bell(Note.a5, at: 0.04, decay: 0.1, gain: 0.05)
        }
        return mix.buffer.map { $0 * master }
    }

    /// 16-bit mono PCM WAV, which `NSSound(data:)` reads directly.
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(sampleRate)
        let bytes = UInt32(samples.count * 2)
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }

    private enum Note {
        static let a3 = 220.0, gSharp3 = 207.65, d4 = 293.66
        static let d5 = 587.33, e5 = 659.25, fSharp5 = 739.99, a5 = 880.0, b5 = 987.77, e6 = 1318.5
    }

    enum Wave { case sine, triangle }

    /// Voices are rendered one by one and summed; times are in seconds from the cue start.
    private struct Mix {
        var buffer: [Float] = []
        /// Fixed seed: the same cue always produces the same samples.
        private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func bell(_ frequency: Double, at start: Double, attack: Double = 0.005, decay: Double,
                           gain: Double, harmonic: Double = 0.18, wave: Wave = .sine,
                           detuneCents: Double = 0, glideTo: Double? = nil, lowpass: Double = 5200) {
            let length = attack + decay + 0.05
            let count = Int(length * sampleRate)
            let detune = pow(2, detuneCents / 1200)
            let glideTime = attack + decay * 0.5
            var voice = [Float](repeating: 0, count: count)
            let partials: [(Double, Double)] = [(1, 1), (2, harmonic), (3, harmonic * 0.25)].filter { $0.1 > 0 }
            for (multiple, amplitude) in partials {
                var phase = 0.0
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    var f = frequency
                    if let glideTo { f = frequency * pow(glideTo / frequency, min(1, t / glideTime)) }
                    phase += f * multiple * detune / sampleRate
                    phase -= phase.rounded(.down)
                    voice[i] += Float(amplitude * Self.oscillator(wave, phase))
                }
            }
            var filter = Biquad.lowpass(lowpass)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                voice[i] = Float(filter.process(Double(voice[i])) * Self.envelope(t, attack: attack, peak: gain, decay: decay))
            }
            add(voice, at: start)
        }

        /// A sine whose pitch falls fast: a soft wooden knock.
        mutating func thock(at start: Double, from: Double = 190, to: Double = 85, decay: Double = 0.09, gain: Double = 0.25) {
            let count = Int((decay + 0.05) * sampleRate)
            var voice = [Float](repeating: 0, count: count)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate
                phase += from * pow(to / from, min(1, t / decay)) / sampleRate
                phase -= phase.rounded(.down)
                voice[i] = Float(sin(2 * .pi * phase) * Self.envelope(t, attack: 0.003, peak: gain, decay: decay))
            }
            add(voice, at: start)
        }

        /// Band-passed white noise: a click when short, a rustle when swept.
        mutating func noise(at start: Double, center: Double, sweepTo: Double? = nil, q: Double = 4,
                            decay: Double = 0.012, gain: Double = 0.25) {
            let count = Int((decay + 0.05) * sampleRate)
            var voice = [Float](repeating: 0, count: count)
            var filter = Biquad.bandpass(center, q: q)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                if let sweepTo { filter = filter.retuned(.bandpass(center * pow(sweepTo / center, min(1, t / decay)), q: q)) }
                voice[i] = Float(filter.process(nextNoise()) * Self.envelope(t, attack: 0.002, peak: gain, decay: decay))
            }
            add(voice, at: start)
        }

        private mutating func add(_ voice: [Float], at start: Double) {
            let offset = Int(start * sampleRate)
            if buffer.count < offset + voice.count { buffer += [Float](repeating: 0, count: offset + voice.count - buffer.count) }
            for (i, sample) in voice.enumerated() { buffer[offset + i] += sample }
        }

        private mutating func nextNoise() -> Double {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(rng >> 11) / Double(1 << 53) * 2 - 1
        }

        private static func oscillator(_ wave: Wave, _ phase: Double) -> Double {
            switch wave {
            case .sine: sin(2 * .pi * phase)
            case .triangle: 1 - 4 * abs(phase - 0.5)
            }
        }

        /// Exponential rise from silence to `peak`, then exponential fall back (Web Audio's ramps).
        private static func envelope(_ t: Double, attack: Double, peak: Double, decay: Double) -> Double {
            let floor = 0.0001
            if t < attack { return floor * pow(peak / floor, t / attack) }
            if t < attack + decay { return peak * pow(floor / peak, (t - attack) / decay) }
            return 0
        }
    }

    /// RBJ cookbook biquad.
    private struct Biquad {
        enum Kind { case lowpass(Double), bandpass(Double, q: Double) }
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        static func lowpass(_ cutoff: Double) -> Biquad { Biquad(.lowpass(cutoff)) }
        static func bandpass(_ center: Double, q: Double) -> Biquad { Biquad(.bandpass(center, q: q)) }

        init(_ kind: Kind) {
            let (f, q): (Double, Double)
            switch kind {
            case .lowpass(let cutoff): (f, q) = (cutoff, 0.7071)
            case .bandpass(let center, let quality): (f, q) = (center, quality)
            }
            let w0 = 2 * .pi * min(f, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q), cosw = cos(w0), a0 = 1 + alpha
            switch kind {
            case .lowpass:
                b0 = (1 - cosw) / 2 / a0; b1 = (1 - cosw) / a0; b2 = b0
            case .bandpass:
                b0 = alpha / a0; b1 = 0; b2 = -alpha / a0
            }
            a1 = -2 * cosw / a0; a2 = (1 - alpha) / a0
        }

        /// New coefficients, same filter memory: a smooth sweep.
        func retuned(_ other: Biquad) -> Biquad {
            var next = other
            next.x1 = x1; next.x2 = x2; next.y1 = y1; next.y2 = y2
            return next
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}
