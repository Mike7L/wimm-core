@preconcurrency import AVFoundation
import Foundation
import WimmInfrastructure

/// Routes microphone buffers on the audio thread into the current note's file and the live
/// sample store, and tells the main actor (through `events`) when `SilenceSplitter` says the
/// note should be sent. The main actor answers with an ordinary `send()`, which swaps the file.
final class SilenceGate: @unchecked Sendable {
    let events: AsyncStream<UInt64>
    private let continuation: AsyncStream<UInt64>.Continuation
    private let lock = NSLock()
    private let store: SampleStore
    private var splitter: SilenceSplitter
    private var sink: AudioFileSink?
    private var speechRevision: UInt64 = 0
    private var isQuiet = true
    private var heardSpeech = false
    private var quietFor = 0.0
    private let quietRMS: Float
    private let closeAfterSeconds: Double
    private let speech: (any SpeechDetecting)?

    init(policy: SilenceSplitPolicy, store: SampleStore, speech: (any SpeechDetecting)? = nil) {
        self.store = store
        self.speech = speech
        quietRMS = policy.quietRMS
        closeAfterSeconds = policy.closeAfterSeconds
        splitter = SilenceSplitter(policy: policy)
        (events, continuation) = AsyncStream.makeStream()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let seconds = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        let rms = Self.rms(buffer)
        lock.lock(); defer { lock.unlock() }
        isQuiet = rms < quietRMS
        if isQuiet { quietFor += seconds } else { speechRevision &+= 1; heardSpeech = true; quietFor = 0 }
        sink?.write(buffer)
        let samples = ParakeetLiveTranscriber.samples16k(from: buffer)
        store.append(samples)
        speech?.feed(samples)
        if splitter.feed(rms: rms, seconds: seconds) { continuation.yield(speechRevision) }
    }

    /// New speech or a new file revokes a queued silence event.
    func isCurrentSilence(_ revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isQuiet && speechRevision == revision
    }

    /// How long the current note has been quiet since its last speech; nil before
    /// any speech. A reading for hosts that need a shorter pause than the split.
    func quietAfterSpeech() -> (seconds: Double, revision: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        return heardSpeech && isQuiet ? (quietFor, speechRevision) : nil
    }

    /// The quiet that will send the current note: seconds already spent and the
    /// seconds that send it. Nil while nothing is pending or splitting is off.
    func pendingSend() -> (quiet: Double, total: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard closeAfterSeconds > 0, heardSpeech, isQuiet else { return nil }
        return (min(quietFor, closeAfterSeconds), closeAfterSeconds)
    }

    /// First note of a recording.
    func start(with newSink: AudioFileSink) {
        lock.lock(); defer { lock.unlock() }
        heardSpeech = false; quietFor = 0
        sink = newSink
        speechRevision &+= 1
        splitter.restart()
    }

    /// A send (manual or by silence): swap files, count silence from scratch. Returns the previous file.
    func swap(to newSink: AudioFileSink) -> AudioFileSink? {
        lock.lock(); defer { lock.unlock() }
        let old = sink
        sink = newSink
        heardSpeech = false; quietFor = 0
        speechRevision &+= 1
        splitter.restart()
        return old
    }

    /// No more silence events. The open file stays writable until `finish()`.
    func endEvents() {
        continuation.finish()
    }

    /// Recording ended; returns the open file.
    func finish() -> AudioFileSink? {
        lock.lock(); defer { lock.unlock() }
        let old = sink
        sink = nil
        continuation.finish()
        return old
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
