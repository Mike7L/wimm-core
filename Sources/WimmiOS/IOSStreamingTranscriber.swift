#if os(iOS)
import Foundation
import AVFoundation
import Speech
import WimmDomain

/// iOS native streaming speech recognizer - transcribes audio in real-time as it's being recorded
@MainActor
class IOSStreamingTranscriber: NSObject, ObservableObject {
    // MARK: - Published State
    @Published private(set) var transcribedText: String = ""
    @Published private(set) var isTranscribing = false
    @Published private(set) var error: Error?
    @Published private(set) var progress: Double = 0.0
    
    @Published var isPaused = false {
        didSet {
            isPausedValue.val = isPaused
        }
    }
    
    private class ThreadSafeBool {
        private let lock = NSLock()
        private var value: Bool = false
        
        var val: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }
    
    private let isPausedValue = ThreadSafeBool()
    
    // MARK: - Private Properties
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Replaced on every route change: after AirPods come or go, the old
    /// engine's input node can keep reporting the previous format while the
    /// hardware already runs another one, and `installTap` then raises an
    /// uncatchable NSException (TestFlight crash, 1.8.1).
    private var audioEngine = AVAudioEngine()
    /// Bumped on every route change and stop, so a delayed retry from an
    /// earlier change never restarts a newer engine or a stopped recording.
    private var routeChangeGeneration = 0
    
    private var startTime: Date?
    private var lastUpdateTime: Date?

    /// On-device recognition resets `bestTranscription` after finalized
    /// utterances. Keep the recording-wide assembly in the shared accumulator
    /// used by the macOS live preview as well.
    private var transcriptAccumulator = StreamingTranscriptAccumulator()
    private var restartPolicy = SessionRestartPolicy()
    /// Set while the user is intentionally stopping, so session-end events don't trigger a restart.
    private var isStopping = false
    /// Battery diagnostics: skip the per-partial log line (off by default).
    var quietPartialLog = false
    
    // Configuration
    private let preferredLocales: [String]
    private let requiresOnDevice: Bool
    
    // MARK: - Initialization
    
    /// Initialize streaming transcriber
    /// - Parameters:
    ///   - locales: Preferred locale identifiers (e.g., ["ru-RU", "en-US"]). Defaults to system locale with Russian fallback.
    ///   - requiresOnDevice: If true, uses only on-device recognition (requires iOS 13+)
    init(locales: [String]? = nil, requiresOnDevice: Bool = true) {
        self.requiresOnDevice = requiresOnDevice
        
        // Determine locale preference
        if let locales = locales {
            self.preferredLocales = locales
        } else if let env = ProcessInfo.processInfo.environment["WIMM_SPEECH_LOCALES"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            self.preferredLocales = env.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            // Default: Russian first, then system locale, then English
            var defaults = ["ru-RU"]
            let systemLocale = Locale.current.identifier
            if systemLocale != "ru-RU" {
                defaults.append(systemLocale)
            }
            if !defaults.contains("en-US") {
                defaults.append("en-US")
            }
            self.preferredLocales = defaults
        }
        
        super.init()
        setupRecognizer()
    }
    
    // MARK: - Setup
    
    private func setupRecognizer() {
        // isAvailable is often false transiently (offline, model still loading after an
        // OS update), so never skip a supported preferred locale because of it — a
        // wrong-language recognizer silently mistranscribes the whole session.
        var firstSupported: SFSpeechRecognizer?
        for localeId in preferredLocales {
            let locale = Locale(identifier: localeId)
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { continue }
            if recognizer.isAvailable {
                speechRecognizer = recognizer
                log("[IOSStreaming] using locale=\(localeId) available=true onDevice=\(recognizer.supportsOnDeviceRecognition)")
                return
            }
            if firstSupported == nil { firstSupported = recognizer }
        }

        if let recognizer = firstSupported {
            speechRecognizer = recognizer
            log("[IOSStreaming] using locale=\(recognizer.locale.identifier) available=false (keeping preferred locale, may become available)")
            return
        }

        // Fallback to system default
        if let recognizer = SFSpeechRecognizer() {
            speechRecognizer = recognizer
            log("[IOSStreaming] fallback to system locale=\(recognizer.locale.identifier) available=\(recognizer.isAvailable)")
        } else {
            log("[IOSStreaming] WARNING: no available speech recognizer found")
        }
    }
    
    // MARK: - Permission
    
    /// Request speech recognition permission
    /// - Returns: true if authorized
    func requestPermission() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        
        let authorized = status == .authorized
        if !authorized {
            log("[IOSStreaming] permission denied: \(status.rawValue)")
        }
        return authorized
    }
    
    // MARK: - Streaming Transcription
    
    /// Start real-time transcription
    func startTranscribing() throws {
        // Drop the previous recording's session and text before anything can
        // throw: a start that fails must not leave the old text to be saved
        // as the new note's live text.
        stopTranscribing()
        transcribedText = ""
        transcriptAccumulator.reset()

        // Availability may have changed since init (connectivity, model download),
        // so re-pick the recognizer if the current one isn't ready.
        if speechRecognizer?.isAvailable != true {
            setupRecognizer()
        }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        
        // Reset state
        restartPolicy.reset()
        error = nil
        progress = 0.0
        startTime = Date()
        lastUpdateTime = nil
        isPaused = false
        isStopping = false

        // The audio session is configured once by `RecordingAudioSession` (the
        // file recorder activates it before starting the transcriber).
        do {
            try startEngineWithTap()
        } catch {
            isTranscribing = false
            throw error
        }

        isTranscribing = true
        observeEngineConfigurationChanges()

        startRecognitionSession(with: speechRecognizer)
    }

    /// Install the tap in the input's current format and start the engine.
    private func startEngineWithTap() throws {
        let inputNode = audioEngine.inputNode
        // installTap raises an uncatchable NSException (SIGABRT) if a tap is already on
        // the bus or the format is invalid, so prevent both instead of handling them.
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard Self.isUsableTapFormat(sampleRate: recordingFormat.sampleRate,
                                     channelCount: recordingFormat.channelCount),
              Self.tapFormatMatchesHardware(
                tapSampleRate: recordingFormat.sampleRate,
                tapChannels: recordingFormat.channelCount,
                hardwareSampleRate: hardwareFormat.sampleRate,
                hardwareChannels: hardwareFormat.channelCount) else {
            log("[IOSStreaming] input format not usable (sr=\(recordingFormat.sampleRate) ch=\(recordingFormat.channelCount) hw.sr=\(hardwareFormat.sampleRate) hw.ch=\(hardwareFormat.channelCount))")
            throw TranscriptionError.audioEngineError
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, !self.isPausedValue.val else { return }
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        log("[IOSStreaming] engine started sr=\(recordingFormat.sampleRate) input=\(RecordingAudioSession.currentInputDescription())")
    }

    // MARK: - Route changes

    private var configurationObserver: NSObjectProtocol?

    /// A route change (AirPods in or out) stops the engine and changes the input
    /// format (HFP is 16 kHz, the iPhone mic 48 kHz). Re-tap in the new format and
    /// start a fresh recognition session; finished text stays in the accumulator.
    private func observeEngineConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        }
    }

    private func stopObservingEngineConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private func handleEngineConfigurationChange() {
        guard isTranscribing, !isStopping else { return }
        log("[IOSStreaming] engine configuration changed input=\(RecordingAudioSession.currentInputDescription())")
        transcribedText = transcriptAccumulator.commitCurrentPartial()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        routeChangeGeneration += 1
        replaceAudioEngine()
        restartAfterRouteChange(generation: routeChangeGeneration, attempt: 0)
    }

    /// Tear the old engine down and start from a fresh one, which reads the
    /// current hardware format instead of a cached one.
    private func replaceAudioEngine() {
        stopObservingEngineConfigurationChanges()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine = AVAudioEngine()
        observeEngineConfigurationChanges()
    }

    /// The route can still be settling when the notification arrives (format
    /// mismatch or zero rate), so retry a few times before giving up on live
    /// text. File recording is separate and continues either way.
    private func restartAfterRouteChange(generation: Int, attempt: Int) {
        guard generation == routeChangeGeneration, isTranscribing, !isStopping,
              let speechRecognizer else { return }
        do {
            try startEngineWithTap()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            if let delay = Self.routeChangeRetryDelay(afterAttempt: attempt) {
                log("[IOSStreaming] restart after route change failed (attempt \(attempt + 1)): \(error.localizedDescription); retrying")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.restartAfterRouteChange(generation: generation, attempt: attempt + 1)
                }
            } else {
                log("[IOSStreaming] restart after route change failed: \(error.localizedDescription); live text stops, file recording continues")
                isTranscribing = false
            }
            return
        }
        restartPolicy.reset()
        startRecognitionSession(with: speechRecognizer)
    }

    /// Start a recognition session. The recognizer ends a session after a pause in speech
    /// (final result or "no speech" error), so we may go through several sessions during
    /// one recording; the shared accumulator preserves every finalized utterance.
    private func startRecognitionSession(with speechRecognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        if requiresOnDevice, speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            Task { @MainActor in
                // A cancelled earlier session (restart, route change, stop) must
                // not restart or overwrite what replaced it. After a stop the
                // request is nil: a late result would append its utterance again.
                guard self.recognitionRequest === request else { return }

                // Update timing
                let now = Date()
                self.lastUpdateTime = now

                if let error = error {
                    self.handleSessionError(error)
                    return
                }

                guard let result = result else { return }

                let segmentText = result.bestTranscription.formattedString
                self.transcribedText = self.transcriptAccumulator.update(
                    partial: segmentText,
                    isFinalized: result.speechRecognitionMetadata != nil || result.isFinal
                )

                // Update progress (estimate based on elapsed time)
                if let startTime = self.startTime {
                    let elapsed = now.timeIntervalSince(startTime)
                    // Progressive progress that slows down over time
                    self.progress = min(0.95, 1.0 - exp(-elapsed / 30.0))
                }

                BatteryProbe.notePartial()

                // Log periodic updates
                if !self.quietPartialLog, let start = self.startTime, now.timeIntervalSince(start) > 1.0 {
                    let elapsed = Int(now.timeIntervalSince(start) * 1000)
                    log("[IOSStreaming] partial result ms=\(elapsed) chars=\(self.transcribedText.count) final=\(result.isFinal)")
                }

                // Session ended (e.g. after a long pause in speech): keep transcribing
                // with a fresh session unless the user is stopping.
                if result.isFinal {
                    if self.isStopping {
                        self.progress = 1.0
                        self.finishTranscription()
                    } else {
                        self.restartRecognitionSession()
                    }
                }
            }
        }
    }

    private func restartRecognitionSession() {
        guard !isStopping, isTranscribing, let speechRecognizer = speechRecognizer else { return }

        if restartPolicy.registerSessionEnd() == .giveUp {
            log("[IOSStreaming] giving up after \(restartPolicy.consecutiveRapidRestarts) rapid session restarts")
            transcribedText = transcriptAccumulator.commitCurrentPartial()
            isTranscribing = false
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        BatteryProbe.noteRestart()
        log("[IOSStreaming] session ended mid-recording, restarting (accumulated chars=\(transcriptAccumulator.committedText.count))")
        startRecognitionSession(with: speechRecognizer)
    }
    
    /// Stop transcription and clean up
    func stopTranscribing() {
        isStopping = true
        routeChangeGeneration += 1
        stopObservingEngineConfigurationChanges()

        // Stop audio engine
        // Always remove the tap: the engine may have stopped on its own (interruption,
        // route change) while the tap stayed installed, and a leftover tap crashes the
        // next installTap.
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil

        transcribedText = transcriptAccumulator.commitCurrentPartial()
        
        isTranscribing = false
        progress = 1.0
        
        // Log final stats
        if let startTime = startTime {
            let elapsed = Date().timeIntervalSince(startTime)
            log("[IOSStreaming] stopped elapsed=\(String(format: "%.1f", elapsed))s chars=\(transcribedText.count)")
        }
    }
    
    /// Finish transcription naturally (called when recognition completes)
    private func finishTranscription() {
        recognitionRequest?.endAudio()
        isTranscribing = false
        
        if let startTime = startTime {
            let elapsed = Date().timeIntervalSince(startTime)
            log("[IOSStreaming] finished elapsed=\(String(format: "%.1f", elapsed))s chars=\(transcribedText.count)")
        }
    }
    
    // MARK: - Error Handling
    
    private func handleSessionError(_ error: Error) {
        let nsError = error as NSError
        log("[IOSStreaming] error domain=\(nsError.domain) code=\(nsError.code) msg=\(nsError.localizedDescription)")

        // While recording, session-level errors (e.g. "no speech detected" after a long
        // pause, or the recognizer ending the session) are recoverable — restart and keep
        // the accumulated text instead of killing the transcription.
        if !isStopping && isTranscribing {
            transcribedText = transcriptAccumulator.commitCurrentPartial()
            restartRecognitionSession()
            return
        }

        self.error = error
        stopTranscribing()
    }
    
    // MARK: - Utility

    /// A tap format is only safe to install when it has a real sample rate and channels.
    nonisolated static func isUsableTapFormat(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }

    /// AVFAudio raises (SIGABRT) when the tap sample rate differs from the input
    /// hardware rate; a stale node after a route change reports the old one.
    nonisolated static func tapFormatMatchesHardware(tapSampleRate: Double, tapChannels: UInt32,
                                                     hardwareSampleRate: Double, hardwareChannels: UInt32) -> Bool {
        isUsableTapFormat(sampleRate: hardwareSampleRate, channelCount: hardwareChannels)
            && isUsableTapFormat(sampleRate: tapSampleRate, channelCount: tapChannels)
            && tapSampleRate == hardwareSampleRate
    }

    /// Delays between restart attempts after a route change; nil = give up.
    nonisolated static func routeChangeRetryDelay(afterAttempt attempt: Int) -> Double? {
        let delays: [Double] = [0.3, 0.7, 1.5]
        return attempt < delays.count ? delays[attempt] : nil
    }
    
    /// Check if speech recognition is available
    var isAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }
    
    /// Current locale being used
    var currentLocale: Locale? {
        speechRecognizer?.locale
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case permissionDenied
    case audioEngineError
    
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available"
        case .permissionDenied:
            return "Speech recognition permission denied"
        case .audioEngineError:
            return "Failed to start audio engine"
        }
    }
}
#endif
