import Foundation
import WimmDomain
import WimmInfrastructure
import AVFoundation
import Combine
import WimmTranscription

public typealias RecordingAudioBufferConsumer = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// State shared between the MainActor recorder and the audio render thread.
/// The tap callback runs off-main, so everything it touches lives here behind
/// a lock instead of on the MainActor-isolated recorder.
private final class AudioTapHub: @unchecked Sendable {
    let levelsSubject = PassthroughSubject<[Float], Never>()
    /// Retained by the recorder; the render thread only borrows it, matching
    /// the previous `[weak file]` capture semantics.
    weak var audioFile: AVAudioFile?

    private let lock = NSLock()
    private var bufferCount = 0
    private var frameCount: AVAudioFramePosition = 0
    private var consumers: [UUID: RecordingAudioBufferConsumer] = [:]

    func resetStats() {
        lock.lock()
        bufferCount = 0
        frameCount = 0
        lock.unlock()
    }

    func snapshotStats() -> (buffers: Int, frames: AVAudioFramePosition) {
        lock.lock()
        defer { lock.unlock() }
        return (bufferCount, frameCount)
    }

    func addConsumer(_ consumer: @escaping RecordingAudioBufferConsumer) -> UUID {
        let id = UUID()
        lock.lock()
        consumers[id] = consumer
        lock.unlock()
        return id
    }

    func removeConsumer(_ id: UUID) {
        lock.lock()
        consumers.removeValue(forKey: id)
        lock.unlock()
    }

    func handle(buffer: AVAudioPCMBuffer, at time: AVAudioTime, fileURL: URL) {
        try? audioFile?.write(from: buffer)

        lock.lock()
        let isFirstBuffer = bufferCount == 0
        bufferCount += 1
        frameCount += AVAudioFramePosition(buffer.frameLength)
        let currentConsumers = Array(consumers.values)
        lock.unlock()

        let levels = Self.computeLevels(from: buffer)
        DispatchQueue.main.async { [levelsSubject] in
            levelsSubject.send(levels)
        }
        if isFirstBuffer {
            UnifiedEventLogger.shared.logAppEvent(
                kind: "recording",
                phase: "audio_first_buffer",
                origin: "UnifiedAudioRecorder.startRecording",
                message: "Audio recorder received first input buffer",
                attributes: [
                    "file": fileURL.lastPathComponent,
                    "frameLength": "\(buffer.frameLength)",
                ],
                source: "UnifiedAudioRecorder"
            )
        }

        for consumer in currentConsumers {
            consumer(buffer, time)
        }
    }

    private static func computeLevels(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        var levels: [Float] = []
        for channel in 0..<channelCount {
            let channelData = data[channel]
            var sum: Float = 0
            for index in 0..<frameLength {
                let sample = channelData[index]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            let db = 20 * log10(max(rms, 1e-6))
            let norm = max(0, min(1, (db + 60) / 60))
            levels.append(norm)
        }
        return levels
    }
}

@MainActor
public final class UnifiedAudioRecorder: AudioRecorderProtocol {

    // MARK: - Properties

    public var isRecording: Bool {
        recordingActive
    }

    public var audioLevelsPublisher: AnyPublisher<[Float], Never> {
        hub.levelsSubject.eraseToAnyPublisher()
    }

    // Used for reporting duration (approximate)
    public var duration: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    // MARK: - Internal State

    private let hub = AudioTapHub()
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingStartedAt: Date?
    private var recordingActive = false

    // MARK: - Lifecycle

    public init() {}

    /// Pre-initializes the audio engine and input chain so the first real
    /// `startRecording()` skips the expensive HAL/graph setup (hundreds of ms).
    /// Does not touch the microphone stream, so no permission prompt and no
    /// mic-in-use indicator. Safe to call multiple times.
    public func prewarm() {
        _ = try? reusableEngine()
    }

    /// Returns the long-lived engine, rebuilding it if the input chain went
    /// stale (e.g. the default input device changed while idle).
    ///
    /// Stale is not only "zero format": after a device or sample-rate switch
    /// (AirPods dropping to HFP, an interface changing rate) a reused engine
    /// keeps reporting the old tap format while the hardware runs at another
    /// rate. `installTap` then raises an Objective-C exception, which Swift
    /// cannot catch — AppKit swallows it on the main thread and leaves the
    /// concurrency runtime's executor tracking dangling, so the app dies a
    /// moment later in an unrelated `@MainActor` check (2026-10-12 crash in
    /// `KeyableWimmHUDPanel.sendEvent`). Validate here and throw instead.
    private func reusableEngine() throws -> (engine: AVAudioEngine, inputFormat: AVAudioFormat) {
        if let engine = audioEngine {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if Self.canInstallTap(format: format, on: engine.inputNode) {
                return (engine, format)
            }
            engine.stop()
            audioEngine = nil
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard Self.canInstallTap(format: format, on: engine.inputNode) else {
            throw NSError(domain: "WimmRecording", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid input audio format"])
        }
        engine.prepare()
        audioEngine = engine
        return (engine, format)
    }

    /// Mirrors AVAudioEngine's own `installTap` precondition (the tap format's
    /// rate must equal the input hardware rate), so a mismatch becomes a Swift
    /// error rather than an uncatchable NSException.
    private static func canInstallTap(format: AVAudioFormat, on inputNode: AVAudioInputNode) -> Bool {
        let hardware = inputNode.inputFormat(forBus: 0)
        return format.sampleRate > 0
            && format.channelCount > 0
            && format.sampleRate == hardware.sampleRate
    }

    // MARK: - AudioRecorderProtocol

    public func startRecording() async throws -> URL {
        // Ensure directory
        try FileStore.ensureDirectoryExists()
        let dir = FileStore.recordingsDirectory()
        let identity = RecordingIdentity()
        let fileURL = FileStore.newRecordingURL(identity: identity, in: dir)

        #if os(iOS)
        // Ensure session is active on iOS
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif

        // Before the AVAudioFile exists, so a rejected format leaves no empty file.
        let (engine, inputFormat) = try reusableEngine()
        let inputNode = engine.inputNode

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: min(Int(inputFormat.channelCount), AudioCfg.channels),
            AVEncoderBitRateKey: AudioCfg.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: aacSettings)
        identity.persist(for: fileURL)
        hub.audioFile = file
        hub.resetStats()

        let hub = self.hub
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable buffer, time in
            hub.handle(buffer: buffer, at: time, fileURL: fileURL)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // A reused engine can fail after audio-route changes; rebuild once.
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            let (freshEngine, freshFormat) = try reusableEngine()
            freshEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: freshFormat) { @Sendable buffer, time in
                hub.handle(buffer: buffer, at: time, fileURL: fileURL)
            }
            freshEngine.prepare()
            try freshEngine.start()
        }

        self.audioFile = file
        self.outputURL = fileURL
        self.recordingStartedAt = Date()
        self.recordingActive = true

        RecordingInputDeviceInspector.current(inputNode: audioEngine?.inputNode)?.stamp(fileURL)

        UnifiedEventLogger.shared.logAppEvent(
            kind: "recording",
            phase: "audio_start",
            origin: "UnifiedAudioRecorder.startRecording",
            message: "Audio recorder started",
            attributes: [
                "file": fileURL.lastPathComponent,
                "sampleRate": String(format: "%.0f", inputFormat.sampleRate),
                "channels": "\(inputFormat.channelCount)",
            ],
            source: "UnifiedAudioRecorder"
        )

        return fileURL
    }
    
    public func stopRecording() async throws -> URL {
        guard recordingActive, let engine = audioEngine, let url = outputURL else {
            throw NSError(domain: "WimmRecording", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }

        recordingActive = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Keep the engine alive (prepared) so the next start skips HAL setup.
        engine.prepare()
        audioFile = nil
        hub.audioFile = nil
        outputURL = nil
        recordingStartedAt = nil
        let stats = hub.snapshotStats()
        let fileSize = Self.fileSize(url)

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        UnifiedEventLogger.shared.logAppEvent(
            kind: "recording",
            phase: "audio_stop",
            origin: "UnifiedAudioRecorder.stopRecording",
            message: "Audio recorder stopped",
            attributes: [
                "file": url.lastPathComponent,
                "fileBytes": "\(fileSize)",
                "bufferCount": "\(stats.buffers)",
                "frameCount": "\(stats.frames)",
            ],
            source: "UnifiedAudioRecorder"
        )
        
        return url
    }
    
    public func cancelRecording() async {
        let engine = audioEngine
        let url = outputURL

        recordingActive = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        // Keep the engine alive (prepared) so the next start skips HAL setup.
        engine?.prepare()
        audioFile = nil
        hub.audioFile = nil
        outputURL = nil
        recordingStartedAt = nil

        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let stats = hub.snapshotStats()
        UnifiedEventLogger.shared.logAppEvent(
            kind: "recording",
            phase: "audio_cancel",
            origin: "UnifiedAudioRecorder.cancelRecording",
            message: "Audio recorder cancelled",
            attributes: [
                "file": url?.lastPathComponent ?? "",
                "bufferCount": "\(stats.buffers)",
                "frameCount": "\(stats.frames)",
            ],
            source: "UnifiedAudioRecorder"
        )
        
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func addRecordingAudioBufferConsumer(_ consumer: @escaping RecordingAudioBufferConsumer) -> UUID {
        hub.addConsumer(consumer)
    }

    public func removeRecordingAudioBufferConsumer(_ id: UUID) {
        hub.removeConsumer(id)
    }

    private nonisolated static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
