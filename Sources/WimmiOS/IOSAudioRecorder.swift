#if os(iOS)
import Foundation
import AVFoundation
import UIKit
import WimmDomain
import WimmInfrastructure

/// iOS audio recorder using AVAudioRecorder
@MainActor
class IOSAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var audioLevels: [Float] = []
    @Published private(set) var recordingURL: URL?
    @Published var transcribedText: String = ""
    @Published var transcriptionProgress: Double = 0.0
    /// Name of the input the recording uses now (e.g. "AirPods Pro"), nil when idle.
    @Published private(set) var inputName: String?
    /// Microphone setting the running recording uses; switchable mid-recording.
    @Published private(set) var microphonePreference = RecordingMicrophonePreference.load()
    /// True while recording when the headset ↔ iPhone switch makes sense.
    @Published private(set) var canSwitchMicrophone = false
    /// The running recording goes through iOS voice processing (trial setting),
    /// so the system microphone modes apply to it.
    @Published private(set) var voiceProcessingActive = false
    /// Latest pulse of the running recording (trial setting), nil without one.
    @Published private(set) var heartRateBPM: Int?
    
    private var audioRecorder: AVAudioRecorder?
    private var isStarting = false
    private var levelTimer: Timer?
    private var streamingTranscriber: IOSStreamingTranscriber?
    private var transcriptionMonitorTask: Task<Void, Never>?
    /// True only while this recording's own live text session was started;
    /// otherwise the transcriber still holds an earlier recording's text.
    private var liveTextStartedForRecording = false
    private var routeObserver: NSObjectProtocol?
    private var inputChanges: [RecordingInputChange] = []
    private var recordingStartedAt = Date()
    /// Battery-measurement switches, read once per recording (all off by default).
    private var diagnostics = BatteryDiagnosticsSettings()
    private lazy var heartRate: RecordingHeartRateCapturing? = {
        let capture = RecordingHeartRate.makeCapture()
        capture?.onReading = { [weak self] bpm in self?.heartRateBPM = bpm }
        return capture
    }()
    
    /// The app is in the background: the waveform and live text are not on screen.
    private var isInBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        setupTranscriber()
        observeAppLifecycle()
    }

    // MARK: - Background

    private func observeAppLifecycle() {
        isInBackground = UIApplication.shared.applicationState == .background
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setInBackground(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setInBackground(false) }
            }
        ]
    }

    /// Stop the screen-only work in the background and bring it back on return.
    private func setInBackground(_ background: Bool) {
        guard background != isInBackground else { return }
        isInBackground = background
        guard isRecording else { return }
        if RecordingScreenWork.runsLevelMeter(inBackground: background,
                                              disabledForDiagnostics: diagnostics.disableLevelMeter) {
            if levelTimer == nil { startLevelMonitoring() }
        } else {
            stopLevelMonitoring()
        }
        if background {
            stopLiveTextPolling()
        } else if liveTextStartedForRecording {
            startLiveTextPolling()   // its first pass shows the text at once
        }
        log("[IOSRecording] background=\(background) levelMeter=\(levelTimer != nil) livePoll=\(transcriptionMonitorTask != nil)")
    }
    
    private func activateAudioSession() throws {
        try RecordingAudioSession.activate()
    }
    
    private func setupTranscriber() {
        streamingTranscriber = IOSStreamingTranscriber()
    }
    
    /// Starts a new recording file. Returns false when no recording runs:
    /// the caller must not treat the note as started (an 18.11 iPhone build
    /// kept a "running" note whose file never got a single packet).
    @discardableResult
    func startRecording() async -> Bool {
        guard !isRecording, !isStarting else { return isRecording }
        isStarting = true
        defer { isStarting = false }
        
        // Request microphone permission
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            print("Microphone permission denied")
            return false
        }

        do {
            // Activate immediately before recording. The shared session may have been
            // changed by playback or another audio feature since app launch.
            try activateAudioSession()
        } catch {
            log("[IOSRecording] start failed: audio session did not activate: \(error)")
            return false
        }
        
        // Request speech recognition permission if transcriber available
        if let transcriber = streamingTranscriber {
            let speechPermission = await transcriber.requestPermission()
            if !speechPermission {
                print("Speech recognition permission denied - continuing without transcription")
            }
        }
        
        // Allocate the durable identity before capture starts. macOS and iOS
        // intentionally use the same human-readable filename format.
        let identity = RecordingIdentity()
        do {
            try FileStore.ensureDirectoryExists()
        } catch {
            print("Failed to prepare recordings directory: \(error)")
            return false
        }
        recordingURL = FileStore.newRecordingURL(
            identity: identity,
            in: DefaultFileStore.shared.audioDirectory()
        )
        
        guard let url = recordingURL else { return false }
        
        // Configure recording settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            guard let started = try await Self.startCaptureRetrying(
                makeRecorder: {
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    recorder.delegate = self
                    recorder.isMeteringEnabled = true
                    recorder.prepareToRecord()
                    return recorder
                },
                start: { $0.record() },
                cleanup: {
                    if !$0.isRecording, $0.currentTime == 0 {
                        $0.deleteRecording()
                    }
                },
                onRetry: { attempt in
                    if attempt == 1 {
                        log("[IOSRecording] record() refused, retrying for up to 3.0s input=\(RecordingAudioSession.currentInputDescription())")
                    }
                    RecordingAudioSession.reapplyPreferredInput()
                }
            ) else {
                throw NSError(
                    domain: "WimmiOS",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"]
                )
            }
            audioRecorder = started.recorder
            if started.attempts > 1 {
                log("[IOSRecording] record() started on attempt \(started.attempts) input=\(RecordingAudioSession.currentInputDescription())")
            }
            identity.persist(for: url)
            NoteOrigin.stamp(url)
            RecordingInputDeviceInspector.current()?.stamp(url)
            DeviceLocation.stampCurrent(for: url)
            inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
            inputChanges = []
            recordingStartedAt = Date()
            startObservingRouteChanges()
            refreshMicrophoneState()
            voiceProcessingActive = RecordingAudioSession.voiceProcessingActive
            noteVoiceProcessing(url: url, atStop: false)
            if RecordingHeartRateSetting.isEnabled() {
                heartRate?.noteStarted(url: url, at: recordingStartedAt)
            }
            
            isRecording = true
            isPaused = false
            audioLevels = []
            transcribedText = ""
            transcriptionProgress = 0.0
            liveTextStartedForRecording = false
            
            diagnostics = BatteryDiagnosticsSettings.current

            // Start level monitoring
            if diagnostics.disableLevelMeter {
                log("[Battery] level meter disabled for this recording")
            } else if RecordingScreenWork.runsLevelMeter(inBackground: isInBackground,
                                                         disabledForDiagnostics: false) {
                startLevelMonitoring()
            }

            // Start streaming transcription
            if diagnostics.disableLiveText {
                log("[Battery] live text disabled for this recording")
            } else {
                startStreamingTranscription()
            }
            
            print("Started recording to: \(url)")
            return true
        } catch {
            log("[IOSRecording] start failed (\(url.lastPathComponent)): \(error.localizedDescription) input=\(RecordingAudioSession.currentInputDescription())")
            abandonFailedStart()
            return false
        }
    }

    nonisolated static let startRetryInterval: TimeInterval = 0.25
    nonisolated static let startRetryCount = 12
    nonisolated static var startRetryDelays: [TimeInterval] {
        Array(repeating: startRetryInterval, count: startRetryCount)
    }

    /// `record()` can refuse right after the session activates while iOS is
    /// still building a Bluetooth HFP route; recreate the recorder across a
    /// bounded 3 s window without tearing down the audio session.
    static func startCaptureRetrying<Recorder>(
        retryDelays: [TimeInterval] = startRetryDelays,
        sleep: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        makeRecorder: () throws -> Recorder,
        start: (Recorder) -> Bool,
        cleanup: (Recorder) -> Void,
        onRetry: ((Int) -> Void)? = nil
    ) async throws -> (recorder: Recorder, attempts: Int)? {
        let initial = try makeRecorder()
        if start(initial) { return (initial, 1) }
        cleanup(initial)

        for (index, delay) in retryDelays.enumerated() {
            let failedAttempt = index + 1
            onRetry?(failedAttempt)
            do {
                try await sleep(delay)
            } catch is CancellationError {
                return nil
            }
            if Task.isCancelled { return nil }
            let recorder = try makeRecorder()
            if start(recorder) { return (recorder, failedAttempt + 1) }
            cleanup(recorder)
        }
        return nil
    }

    /// A start that never recorded: drop its header-only file (it holds no
    /// audio, so it is not an original) and leave no state that a caller could
    /// mistake for a running note, including the previous note's live text.
    private func abandonFailedStart() {
        if let recorder = audioRecorder, !recorder.isRecording, recorder.currentTime == 0 {
            recorder.deleteRecording()
        }
        audioRecorder = nil
        recordingURL = nil
        transcribedText = ""
        releaseSession()
    }

    /// Deactivate the shared session so other apps' audio can resume.
    func releaseSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    func pauseRecording() {
        guard isRecording else { return }
        audioRecorder?.pause()
        streamingTranscriber?.isPaused = true
        isPaused = true
        print("Recording paused")
    }
    
    func resumeRecording() {
        guard isRecording else { return }
        audioRecorder?.record()
        streamingTranscriber?.isPaused = false
        isPaused = false
        print("Recording resumed")
    }
    
    /// `keepingSessionActive`: a split starts the next note at once. Turning
    /// the session off and on between them made iOS rebuild the route and
    /// stop the new recorder within milliseconds (iPhone log, 18.11).
    func stopRecording(keepingSessionActive: Bool = false) async {
        guard isRecording, let url = recordingURL else { return }
        
        stopObservingRouteChanges()
        stopLevelMonitoring()
        stopStreamingTranscription()
        noteVoiceProcessing(url: url, atStop: true)
        voiceProcessingActive = false
        heartRate?.noteStopped()
        
        audioRecorder?.stop()
        isRecording = false
        isPaused = false
        canSwitchMicrophone = false

        if !keepingSessionActive { releaseSession() }
        
        print("Recording saved to: \(url)")
        print("Final transcription: \(transcribedText)")
        
        audioRecorder = nil
        recordingURL = nil
        inputName = nil
    }

    /// A voice-processed original says so in its sidecar, with the system mic
    /// mode at start and at stop (the user can change it mid-recording).
    private func noteVoiceProcessing(url: URL, atStop: Bool) {
        guard voiceProcessingActive else { return }
        let key = atStop ? "micModeAtStop" : "micModeAtStart"
        let mode = RecordingAudioSession.activeMicrophoneModeName()
        do {
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: url)) { sidecar in
                var value = sidecar["audioVoiceProcessing"] as? [String: Any] ?? ["sessionMode": "videoChat"]
                value[key] = mode
                sidecar["audioVoiceProcessing"] = value
                return true
            }
        } catch {
            log("[IOSRecording] voice-processing note failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Route changes

    private func startObservingRouteChanges() {
        stopObservingRouteChanges()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            Task { @MainActor in self?.handleRouteChange(reason) }
        }
    }

    private func stopObservingRouteChanges() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// The user picked headset or iPhone mic on the recording screen. The file
    /// keeps going; the switch is noted like any other input change.
    func switchMicrophone(to preference: RecordingMicrophonePreference) {
        guard isRecording, recordingURL != nil else { return }
        do {
            try RecordingAudioSession.switchActiveSession(to: preference)
        } catch {
            log("[IOSRecording] mic switch to \(preference.rawValue) failed: \(error.localizedDescription)")
        }
        refreshMicrophoneState()
        resumeRecorderIfStopped()
        noteInputChange(reason: "userSwitch")
    }

    private func refreshMicrophoneState() {
        microphonePreference = .load()
        canSwitchMicrophone = RecordingAudioSession.canSwitchMicrophone(
            preference: microphonePreference,
            availablePorts: RecordingAudioSession.availableInputPorts())
    }

    private func resumeRecorderIfStopped() {
        guard let recorder = audioRecorder, !isPaused, !recorder.isRecording else { return }
        log("[IOSRecording] recorder stopped by route change, resume=\(recorder.record())")
    }

    /// AirPods in or out mid-recording: keep the file going on the new input and
    /// note the switch in the sidecar (`audioInputChanges`).
    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        guard isRecording, let recorder = audioRecorder else { return }
        RecordingAudioSession.reapplyPreferredInput()
        log("[IOSRecording] route change reason=\(RecordingAudioSession.describe(reason)) input=\(RecordingAudioSession.currentInputDescription()) recording=\(recorder.isRecording)")
        resumeRecorderIfStopped()
        refreshMicrophoneState()
        noteInputChange(reason: RecordingAudioSession.describe(reason))
    }

    /// Record a new input in the sidecar (`audioInputChanges`) if it changed.
    private func noteInputChange(reason: String) {
        guard let url = recordingURL,
              let input = AVAudioSession.sharedInstance().currentRoute.inputs.first,
              input.portName != inputName else { return }
        inputName = input.portName
        inputChanges.append(RecordingInputChange(
            offset: Date().timeIntervalSince(recordingStartedAt),
            name: input.portName, transport: input.portType.rawValue,
            reason: reason))
        FileStore.upsertMetadata(for: url, updates: [
            RecordingInputChange.metadataKey: inputChanges.map(\.sidecarValue)
        ])
    }
    
    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Only capture `self` weakly outside, then hop to the main actor for property access.
            guard let self = self else { return }
            Task { @MainActor in
                guard let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                let level = recorder.averagePower(forChannel: 0)
                
                // Convert dB to normalized 0-1 range
                let normalizedLevel = self.normalizeSoundLevel(level: level)
                
                self.audioLevels.append(normalizedLevel)
                if self.audioLevels.count > 50 {
                    self.audioLevels.removeFirst()
                }
            }
        }
    }
    
    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
    
    @MainActor
    private func normalizeSoundLevel(level: Float) -> Float {
        // dB range is typically -160 to 0
        // Normalize to 0-1
        let minDb: Float = -80
        let maxDb: Float = 0
        
        let clampedLevel = max(minDb, min(maxDb, level))
        return (clampedLevel - minDb) / (maxDb - minDb)
    }
    
    // MARK: - Streaming Transcription
    
    private func startStreamingTranscription() {
        guard let transcriber = streamingTranscriber else { return }
        transcriber.quietPartialLog = diagnostics.quietLiveLog

        do {
            try transcriber.startTranscribing()
            liveTextStartedForRecording = true
            
            if RecordingScreenWork.pollsLiveText(inBackground: isInBackground) { startLiveTextPolling() }
        } catch {
            print("Failed to start streaming transcription: \(error)")
        }
    }
    
    /// Copy the live text to the screen once a second, only while Wimm is in
    /// the foreground. The autosave reads the transcriber directly
    /// (`currentLiveText`), so stopping this poll loses nothing.
    private func startLiveTextPolling() {
        guard let transcriber = streamingTranscriber else { return }
        transcriptionMonitorTask?.cancel()
        transcriptionMonitorTask = Task {
            while !Task.isCancelled && transcriber.isTranscribing {
                syncLiveText()
                try? await Task.sleep(nanoseconds: RecordingScreenWork.liveTextPollNanoseconds)
            }
        }
    }

    private func stopLiveTextPolling() {
        transcriptionMonitorTask?.cancel()
        transcriptionMonitorTask = nil
    }

    private func syncLiveText() {
        guard liveTextStartedForRecording, let transcriber = streamingTranscriber else { return }
        if transcribedText != transcriber.transcribedText { transcribedText = transcriber.transcribedText }
        transcriptionProgress = transcriber.progress
    }

    /// Live text heard so far, read from the transcriber itself rather than
    /// the screen copy, which stands still while Wimm is in the background.
    var currentLiveText: String {
        if liveTextStartedForRecording, let transcriber = streamingTranscriber {
            return transcriber.transcribedText
        }
        return transcribedText
    }

    private func stopStreamingTranscription() {
        stopLiveTextPolling()
        streamingTranscriber?.stopTranscribing()
        
        // Get final transcription, only from this recording's own session.
        if liveTextStartedForRecording, let finalText = streamingTranscriber?.transcribedText {
            transcribedText = finalText
        }
        liveTextStartedForRecording = false
        transcriptionProgress = 1.0
    }
    
    // MARK: - AVAudioRecorderDelegate
    
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                print("Recording failed")
                self.heartRate?.noteStopped()
                self.isRecording = false
                self.audioRecorder = nil
                self.recordingURL = nil
            }
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            print("Recording error: \(error?.localizedDescription ?? "unknown")")
            self.heartRate?.noteStopped()
            self.isRecording = false
            self.audioRecorder = nil
            self.recordingURL = nil
        }
    }
}
#endif
