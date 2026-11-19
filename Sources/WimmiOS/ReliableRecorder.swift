#if os(iOS)
import Foundation
import AVFoundation
import Combine
import WimmDomain
import WimmInfrastructure

/// Reliable wrapper around IOSAudioRecorder that auto-saves metadata during recording.
/// Ensures that transcriptions and metadata are persisted to disk every 5 seconds,
/// protecting against data loss in case of app crashes.
@MainActor
class ReliableRecorder: ObservableObject {
    // MARK: - Published Properties
    
    /// Whether recording is currently active
    @Published var isRecording = false
    
    /// Whether recording is currently paused
    @Published var isPaused = false
    
    /// Timestamp of the last successful metadata save
    @Published var lastSaveTime: Date?
    
    /// Whether a save operation is currently in progress
    @Published var isSaving = false
    
    /// Current transcribed text from the recorder
    @Published var transcribedText: String = ""
    
    /// Audio levels for visualization (delegated from baseRecorder)
    @Published var audioLevels: [Float] = []
    
    /// Input the recording uses now (e.g. "AirPods Pro"), nil when idle
    @Published var inputName: String?

    /// Microphone setting of the running recording (headset or iPhone mic)
    @Published var microphonePreference = RecordingMicrophonePreference.load()

    /// Whether the recording screen offers the headset ↔ iPhone switch
    @Published var canSwitchMicrophone = false

    /// Latest pulse of the running recording (trial setting), nil without one
    @Published var heartRateBPM: Int?

    /// The recording goes through iOS voice processing (trial setting)
    @Published var voiceProcessingActive = false
    
    /// Transcription progress (0.0 to 1.0)
    @Published var transcriptionProgress: Double = 0.0

    /// Bumped each time a recording could not start or stopped on its own;
    /// the capture screen tells the user instead of showing a running timer.
    @Published private(set) var failureCount = 0
    
    /// Current recording URL (nil when not recording)
    var recordingURL: URL? {
        return currentRecordingURL
    }
    
    // MARK: - Private Properties
    
    private let baseRecorder = IOSAudioRecorder()
    private var metadataTimer: Timer?
    private let repository = IOSRecordingRepository.shared
    private var cancellables = Set<AnyCancellable>()
    private var bindings = Set<AnyCancellable>()
    private var currentRecordingURL: URL?
    private var recordingStartTime: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var lastResumeTime: Date?
    /// Set while this wrapper itself stops or splits, so the base recorder
    /// going idle then is not taken for a recorder that died.
    private var isTransitioning = false
    /// Battery-measurement switches for this recording session (all off by default).
    private var diagnostics = BatteryDiagnosticsSettings()
    
    // MARK: - Initialization
    
    init() {
        setupBindings()
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Forward published properties from baseRecorder
        baseRecorder.$transcribedText
            .assign(to: &$transcribedText)
        
        baseRecorder.$audioLevels
            .assign(to: &$audioLevels)
        
        baseRecorder.$transcriptionProgress
            .assign(to: &$transcriptionProgress)
            
        baseRecorder.$isPaused
            .assign(to: &$isPaused)

        baseRecorder.$inputName
            .assign(to: &$inputName)

        baseRecorder.$microphonePreference
            .assign(to: &$microphonePreference)

        baseRecorder.$canSwitchMicrophone
            .assign(to: &$canSwitchMicrophone)

        baseRecorder.$heartRateBPM
            .assign(to: &$heartRateBPM)

        baseRecorder.$voiceProcessingActive
            .assign(to: &$voiceProcessingActive)

        // The file recorder can end on its own (encode error, a failed
        // finish); the note must end with it rather than keep a clock running.
        baseRecorder.$isRecording
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.baseRecorderStopped() }
            }
            .store(in: &bindings)
    }
    
    // MARK: - Public API
    
    /// Starts recording and begins auto-saving metadata every 5 seconds
    func startRecording() async {
        guard !isRecording else { return }

        diagnostics = BatteryDiagnosticsSettings.current
        BatteryProbe.shared.recordingStarted(settings: diagnostics)

        // Start the underlying recorder
        guard await baseRecorder.startRecording() else {
            BatteryProbe.shared.recordingStopped()
            failureCount += 1
            return
        }
        
        // Update state
        isRecording = true
        accumulatedDuration = 0
        lastResumeTime = Date()
        recordingStartTime = Date()
        currentRecordingURL = baseRecorder.recordingURL
        
        // Start auto-save timer
        startAutoSave()
        
        // Save initial metadata immediately
        await saveMetadataSnapshot()
    }
    
    /// Switch between headset and iPhone mic without stopping the recording
    func switchMicrophone(to preference: RecordingMicrophonePreference) {
        baseRecorder.switchMicrophone(to: preference)
    }

    /// Pauses the active recording
    func pauseRecording() {
        guard isRecording && !isPaused else { return }
        baseRecorder.pauseRecording()
        if let lastResume = lastResumeTime {
            accumulatedDuration += Date().timeIntervalSince(lastResume)
        }
        lastResumeTime = nil
    }
    
    /// Resumes the paused recording
    func resumeRecording() {
        guard isRecording && isPaused else { return }
        baseRecorder.resumeRecording()
        lastResumeTime = Date()
    }
    
    /// Finalizes the current recording segment and immediately starts a new one
    /// - Returns: The URL of the finalized segment
    func splitRecording() async -> URL? {
        guard isRecording else { return nil }
        
        let finalizedURL = currentRecordingURL
        
        // 1. Stop auto-save timer
        stopAutoSave()
        
        // 2. Add final active segment duration before stopping
        if !isPaused, let lastResume = lastResumeTime {
            accumulatedDuration += Date().timeIntervalSince(lastResume)
        }
        lastResumeTime = nil
        
        // 3. Stop the underlying baseRecorder (saves file and finishes transcriber).
        // Capture the transcription only after the stop: stopping flushes the
        // transcriber's final utterance into transcribedText. The session
        // stays on: the next note starts right away.
        isTransitioning = true
        defer { isTransitioning = false }
        await baseRecorder.stopRecording(keepingSessionActive: true)
        let finalTranscription = baseRecorder.transcribedText
        
        // 4. Save final metadata for this segment with isComplete=true
        if let url = finalizedURL {
            let duration = await Self.savedDuration(clock: accumulatedDuration, url: url)
            let metadata = RecordingMetadata(
                recordingURL: url,
                transcription: finalTranscription,
                duration: duration,
                timestamp: recordingStartTime ?? Date(),
                isComplete: true,
                lastSaved: Date()
            )
            do {
                try await repository.saveMetadata(for: url, metadata: metadata)
                FileStore.storeLiveText(finalTranscription, for: url)
                print("ReliableRecorder: Split completed segment metadata saved for \(url.lastPathComponent)")
            } catch {
                print("ReliableRecorder: Failed to save split segment metadata: \(error)")
            }
        }
        
        // 5. Start new recording segment; if it cannot start, the session
        // ends here (the finished note above is kept) and the user is told.
        guard await baseRecorder.startRecording() else {
            baseRecorder.releaseSession()
            BatteryProbe.shared.recordingStopped()
            endSession()
            failureCount += 1
            return finalizedURL
        }
        
        // 6. Update local state
        accumulatedDuration = 0
        lastResumeTime = Date()
        recordingStartTime = Date()
        currentRecordingURL = baseRecorder.recordingURL
        
        // 7. Restart auto-save
        startAutoSave()
        await saveMetadataSnapshot()
        
        return finalizedURL
    }
    
    /// Stops recording, saves final metadata with isComplete=true, and cleans up
    func stopRecording() async {
        guard isRecording else { return }
        
        // Stop auto-save timer first
        stopAutoSave()
        
        // Add final active segment duration before stopping
        if !isPaused, let lastResume = lastResumeTime {
            accumulatedDuration += Date().timeIntervalSince(lastResume)
        }
        lastResumeTime = nil
        
        // Stop the underlying recorder
        isTransitioning = true
        defer { isTransitioning = false }
        if baseRecorder.isRecording {
            await baseRecorder.stopRecording()
        } else {
            baseRecorder.releaseSession()   // it ended on its own and kept the session
        }
        BatteryProbe.shared.recordingStopped()

        // Save final metadata with isComplete=true, stating what the file holds
        var finalDuration: TimeInterval?
        if let url = currentRecordingURL {
            finalDuration = await Self.savedDuration(clock: accumulatedDuration, url: url)
        }
        await saveMetadataSnapshot(isComplete: true, duration: finalDuration)
        
        endSession()
    }

    private func endSession() {
        stopAutoSave()
        isRecording = false
        currentRecordingURL = nil
        recordingStartTime = nil
        lastResumeTime = nil
        lastSaveTime = nil
        accumulatedDuration = 0
    }

    /// The base recorder went idle without this wrapper asking: finish the
    /// note with what the file holds and report it.
    private func baseRecorderStopped() async {
        // Checked when the hop runs, not when the change was published: by
        // then a split may already have started the next file.
        guard isRecording, !isTransitioning, !baseRecorder.isRecording else { return }
        log("[IOSRecording] recorder stopped on its own; ending the note")
        await stopRecording()
        failureCount += 1
    }
    
    // MARK: - Auto-Save Logic
    
    private func startAutoSave() {
        Timer.publish(every: diagnostics.autosaveInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.saveMetadataSnapshot()
                }
            }
            .store(in: &cancellables)
    }
    
    private func stopAutoSave() {
        cancellables.removeAll()
    }
    
    /// Saves a snapshot of current recording metadata to disk
    /// - Parameter isComplete: Whether this is the final save (recording complete)
    /// - Parameter finalDuration: the reconciled duration of a finished file
    private func saveMetadataSnapshot(isComplete: Bool = false, duration finalDuration: TimeInterval? = nil) async {
        guard let recordingURL = currentRecordingURL else { return }
        
        isSaving = true
        defer { isSaving = false }
        
        // Calculate duration
        let duration: TimeInterval
        if let finalDuration {
            duration = finalDuration
        } else if isPaused {
            duration = accumulatedDuration
        } else if let lastResume = lastResumeTime {
            duration = accumulatedDuration + Date().timeIntervalSince(lastResume)
        } else {
            duration = accumulatedDuration
        }
        
        // Live text straight from the transcriber: the screen poll that feeds
        // `transcribedText` stops in the background, the autosave must not.
        let liveText = baseRecorder.currentLiveText

        // Create metadata object
        let metadata = RecordingMetadata(
            recordingURL: recordingURL,
            transcription: liveText,
            duration: duration,
            timestamp: recordingStartTime ?? Date(),
            isComplete: isComplete,
            lastSaved: Date()
        )
        
        // Save to disk
        do {
            try await repository.saveMetadata(for: recordingURL, metadata: metadata)
            // Live text in the shape Studio writes (`localTranscript` plus a
            // copy in `transcript`), so every device reads it as live text.
            FileStore.storeLiveText(liveText, for: recordingURL)
            lastSaveTime = Date()
            print("ReliableRecorder: Saved metadata snapshot (isComplete: \(isComplete)) at \(lastSaveTime!)")
        } catch {
            print("ReliableRecorder: Failed to save metadata: \(error)")
        }
    }
    
    /// The finalized file's length, not the clock's: an old build kept counting
    /// after the file stopped growing and promised minutes that were never saved.
    private static func savedDuration(clock: TimeInterval, url: URL) async -> TimeInterval {
        let verdict = RecordedDuration.reconcile(clock: clock, file: await RecordedDuration.fileSeconds(of: url))
        if verdict.unsavedSeconds > 0 {
            log("[IOSRecording] file holds \(Int(verdict.seconds)) s of \(Int(clock)) s recorded; \(Int(verdict.unsavedSeconds)) s were not saved (\(url.lastPathComponent))")
        }
        return verdict.seconds
    }

    // MARK: - Cleanup
    
    deinit {
        // cancellables are cleared automatically
    }
}
#endif
