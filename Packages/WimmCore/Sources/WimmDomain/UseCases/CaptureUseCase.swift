import Foundation

/// Result of a full capture session (record → transcribe → save → analyze).
public struct CaptureResult: Sendable {
    /// The persisted CapturedNote created from this session.
    public let note: CapturedNote
    /// Raw transcript produced by speech recognition.
    public let transcript: String
    /// Whether the analysis step succeeded (false if analysis failed but note was saved).
    public let analysisSucceeded: Bool
}

/// Orchestrates a live microphone capture session:
///   1. Start streaming recognition via ``TranscriptionPort``.
///   2. Stop on demand, obtain audio data + transcript.
///   3. Persist via ``StoragePort``.
///   4. Analyse via ``AnalysisPort`` and update the note.
///
/// Replaces the legacy `M4AAudioRecorder` usage in the macOS app for the WIMM code path.
public struct CaptureUseCase: Sendable {
    private let transcription: TranscriptionPort
    private let analysis: AnalysisPort
    private let storage: StoragePort

    // TODO: Replace with a proper Sendable wrapper once ISO8601DateFormatter gains Sendable conformance (rdar://FB9673325).
    nonisolated(unsafe) private static let filenameDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    public init(
        transcription: TranscriptionPort,
        analysis: AnalysisPort,
        storage: StoragePort
    ) {
        self.transcription = transcription
        self.analysis = analysis
        self.storage = storage
    }

    // MARK: - Streaming phase

    /// Begin microphone capture.
    /// - Returns: An ``AsyncThrowingStream`` of partial recognition results.
    ///            Consume it in the UI to show live transcription.
    public func startCapture() throws -> AsyncThrowingStream<String, Error> {
        try transcription.startStreamingCapture()
    }

    // MARK: - Stop + persist + analyse

    /// Stop capture, persist the recording, run analysis, and return a ``CaptureResult``.
    ///
    /// - Parameter dryRun: When `true`, skip persistence and analysis (testing / preview).
    /// - Returns: A ``CaptureResult`` with the saved note and its analysis status.
    public func stopAndProcess(dryRun: Bool = false) async throws -> CaptureResult {
        // Short-circuit before touching the audio hardware when dry-running.
        // Calling stopCapture() on NativeSpeechAdapter without a prior startCapture()
        // is safe (isCapturing guard returns early) but returns empty data — misleading.
        // Return a stub immediately instead.
        guard !dryRun else {
            let stub = CapturedNote(
                id: UUID(),
                createdAt: Date(),
                text: "[dry-run]",
                audioPath: nil,
                status: .pendingAnalysis
            )
            return CaptureResult(note: stub, transcript: "[dry-run]", analysisSucceeded: false)
        }

        // 1. Stop microphone, get audio data + transcript.
        let (audioData, transcript) = try await transcription.stopCapture()

        // 2. Persist audio + transcript.
        //    fileName is derived from a timestamp so every capture is unique.
        let fileName = "capture_\(CaptureUseCase.filenameDateFormatter.string(from: Date())).m4a"
        var note = try await storage.saveRecording(data: audioData, fileName: fileName, initialText: transcript)

        // 3. Analyse transcript.
        var analysisSucceeded = false
        do {
            note.card = try await analysis.analyze(text: transcript)
            note.status = .completed
            try await storage.updateNote(note)
            analysisSucceeded = true
        } catch {
            let retryable = RetryPolicy.isRetryable(error)
            note.status = .failed(reason: error.localizedDescription, retryable: retryable)
            try await storage.updateNote(note)
        }

        return CaptureResult(note: note, transcript: transcript, analysisSucceeded: analysisSucceeded)
    }
}
