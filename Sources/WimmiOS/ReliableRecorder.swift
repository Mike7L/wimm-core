#if os(iOS)
import Foundation
import AVFoundation
import Combine
import WimmDomain

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
    
    /// Transcription progress (0.0 to 1.0)
    @Published var transcriptionProgress: Double = 0.0
    
    /// Current recording URL (nil when not recording)
    var recordingURL: URL? {
        return currentRecordingURL
    }
    
    // MARK: - Private Properties
    
    private let baseRecorder = IOSAudioRecorder()
    private var metadataTimer: Timer?
    private let repository = IOSRecordingRepository.shared
    private var cancellables = Set<AnyCancellable>()
    private var currentRecordingURL: URL?
    private var recordingStartTime: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var lastResumeTime: Date?
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
    }
    
    // MARK: - Public API
    
    /// Starts recording and begins auto-saving metadata every 5 seconds
    func startRecording() async {
        guard !isRecording else { return }

        diagnostics = BatteryDiagnosticsSettings.current
        BatteryProbe.shared.recordingStarted(settings: diagnostics)

        // Start the underlying recorder
        await baseRecorder.startRecording()
        
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
        // transcriber's final utterance into transcribedText.
        await baseRecorder.stopRecording()
        let finalTranscription = baseRecorder.transcribedText
        
        // 4. Save final metadata for this segment with isComplete=true
        if let url = finalizedURL {
            let metadata = RecordingMetadata(
                recordingURL: url,
                transcription: finalTranscription,
                duration: accumulatedDuration,
                timestamp: recordingStartTime ?? Date(),
                isComplete: true,
                lastSaved: Date()
            )
            do {
                try await repository.saveMetadata(for: url, metadata: metadata)
                print("ReliableRecorder: Split completed segment metadata saved for \(url.lastPathComponent)")
            } catch {
                print("ReliableRecorder: Failed to save split segment metadata: \(error)")
            }
        }
        
        // 5. Start new recording segment
        await baseRecorder.startRecording()
        
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
        await baseRecorder.stopRecording()
        BatteryProbe.shared.recordingStopped()

        // Save final metadata with isComplete=true
        await saveMetadataSnapshot(isComplete: true)
        
        // Update state
        isRecording = false
        currentRecordingURL = nil
        recordingStartTime = nil
        lastSaveTime = nil
        accumulatedDuration = 0
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
    private func saveMetadataSnapshot(isComplete: Bool = false) async {
        guard let recordingURL = currentRecordingURL else { return }
        
        isSaving = true
        defer { isSaving = false }
        
        // Calculate duration
        let duration: TimeInterval
        if isPaused {
            duration = accumulatedDuration
        } else if let lastResume = lastResumeTime {
            duration = accumulatedDuration + Date().timeIntervalSince(lastResume)
        } else {
            duration = accumulatedDuration
        }
        
        // Create metadata object
        let metadata = RecordingMetadata(
            recordingURL: recordingURL,
            transcription: transcribedText,
            duration: duration,
            timestamp: recordingStartTime ?? Date(),
            isComplete: isComplete,
            lastSaved: Date()
        )
        
        // Save to disk
        do {
            try await repository.saveMetadata(for: recordingURL, metadata: metadata)
            lastSaveTime = Date()
            print("ReliableRecorder: Saved metadata snapshot (isComplete: \(isComplete)) at \(lastSaveTime!)")
        } catch {
            print("ReliableRecorder: Failed to save metadata: \(error)")
        }
    }
    
    // MARK: - Cleanup
    
    deinit {
        // cancellables are cleared automatically
    }
}
#endif
