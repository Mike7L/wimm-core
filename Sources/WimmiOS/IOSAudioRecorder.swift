#if os(iOS)
import Foundation
import AVFoundation
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
    
    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var streamingTranscriber: IOSStreamingTranscriber?
    private var transcriptionMonitorTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private var inputChanges: [RecordingInputChange] = []
    private var recordingStartedAt = Date()
    /// Battery-measurement switches, read once per recording (all off by default).
    private var diagnostics = BatteryDiagnosticsSettings()
    
    override init() {
        super.init()
        setupTranscriber()
    }
    
    private func activateAudioSession() throws {
        try RecordingAudioSession.activate()
    }
    
    private func setupTranscriber() {
        streamingTranscriber = IOSStreamingTranscriber()
    }
    
    func startRecording() async {
        guard !isRecording else { return }
        
        // Request microphone permission
        let permissionGranted = await AVAudioApplication.requestRecordPermission()
        guard permissionGranted else {
            print("Microphone permission denied")
            return
        }

        do {
            // Activate immediately before recording. The shared session may have been
            // changed by playback or another audio feature since app launch.
            try activateAudioSession()
        } catch {
            print("Failed to activate audio session: \(error)")
            return
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
            return
        }
        recordingURL = FileStore.newRecordingURL(
            identity: identity,
            in: DefaultFileStore.shared.audioDirectory()
        )
        
        guard let url = recordingURL else { return }
        
        // Configure recording settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            guard audioRecorder?.record() == true else {
                throw NSError(
                    domain: "WimmiOS",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"]
                )
            }
            identity.persist(for: url)
            NoteOrigin.stamp(url)
            RecordingInputDeviceInspector.current()?.stamp(url)
            inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
            inputChanges = []
            recordingStartedAt = Date()
            startObservingRouteChanges()
            
            isRecording = true
            isPaused = false
            audioLevels = []
            transcribedText = ""
            transcriptionProgress = 0.0
            
            diagnostics = BatteryDiagnosticsSettings.current

            // Start level monitoring
            if diagnostics.disableLevelMeter {
                log("[Battery] level meter disabled for this recording")
            } else {
                startLevelMonitoring()
            }

            // Start streaming transcription
            if diagnostics.disableLiveText {
                log("[Battery] live text disabled for this recording")
            } else {
                startStreamingTranscription()
            }
            
            print("Started recording to: \(url)")
        } catch {
            print("Failed to start recording: \(error)")
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
    
    func stopRecording() async {
        guard isRecording, let url = recordingURL else { return }
        
        stopObservingRouteChanges()
        stopLevelMonitoring()
        stopStreamingTranscription()
        
        audioRecorder?.stop()
        isRecording = false
        isPaused = false

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        print("Recording saved to: \(url)")
        print("Final transcription: \(transcribedText)")
        
        audioRecorder = nil
        recordingURL = nil
        inputName = nil
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

    /// AirPods in or out mid-recording: keep the file going on the new input and
    /// note the switch in the sidecar (`audioInputChanges`).
    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        guard isRecording, let url = recordingURL, let recorder = audioRecorder else { return }
        RecordingAudioSession.reapplyPreferredInput()
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        log("[IOSRecording] route change reason=\(RecordingAudioSession.describe(reason)) input=\(RecordingAudioSession.currentInputDescription()) recording=\(recorder.isRecording)")
        if !isPaused && !recorder.isRecording {
            log("[IOSRecording] recorder stopped by route change, resume=\(recorder.record())")
        }
        guard let input, input.portName != inputName else { return }
        inputName = input.portName
        inputChanges.append(RecordingInputChange(
            offset: Date().timeIntervalSince(recordingStartedAt),
            name: input.portName, transport: input.portType.rawValue,
            reason: RecordingAudioSession.describe(reason)))
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
            
            // Monitor transcription progress
            transcriptionMonitorTask?.cancel()
            transcriptionMonitorTask = Task {
                while !Task.isCancelled && transcriber.isTranscribing {
                    transcribedText = transcriber.transcribedText
                    transcriptionProgress = transcriber.progress
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
            }
        } catch {
            print("Failed to start streaming transcription: \(error)")
        }
    }
    
    private func stopStreamingTranscription() {
        transcriptionMonitorTask?.cancel()
        transcriptionMonitorTask = nil
        streamingTranscriber?.stopTranscribing()
        
        // Get final transcription
        if let finalText = streamingTranscriber?.transcribedText {
            transcribedText = finalText
        }
        transcriptionProgress = 1.0
    }
    
    // MARK: - AVAudioRecorderDelegate
    
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                print("Recording failed")
                self.isRecording = false
                self.audioRecorder = nil
                self.recordingURL = nil
            }
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            print("Recording error: \(error?.localizedDescription ?? "unknown")")
            self.isRecording = false
            self.audioRecorder = nil
            self.recordingURL = nil
        }
    }
}
#endif
