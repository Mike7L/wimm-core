import Foundation

/// Результат обработки файла через ProcessFileUseCase.
public struct ProcessFileResult: Sendable {
    public let note: CapturedNote
    /// true если транскрипция происходила («audio -> text»), false — если текст уже был в sidecar.
    public let didTranscribe: Bool

    public init(note: CapturedNote, didTranscribe: Bool) {
        self.note = note
        self.didTranscribe = didTranscribe
    }
}

/// Режим транскрипции при обработке файла.
public enum TranscriptionMode: Sendable {
    /// Транскрибировать только если текст ещё пустой.
    case ifMissing
    /// Всегда перетранскрибировать, даже если текст есть.
    case always
    /// Никогда не транскрибировать (использовать только то, что есть в sidecar).
    case skip
}

/// Обрабатывает существующий аудиофайл с диска — транскрибирует и анализирует.
///
/// Сценарии использования:
/// - `wimm process <path>` — ручная отправка файла в пайплайн без GUI.
/// - Обработка импортированных файлов из внешнего источника.
/// - Повторная транскрипция/анализ конкретного файла.
public struct ProcessFileUseCase: Sendable {
    private let storage: StoragePort
    private let transcription: TranscriptionPort
    private let analysis: AnalysisPort
    public init(storage: StoragePort, transcription: TranscriptionPort, analysis: AnalysisPort) {
        self.storage = storage
        self.transcription = transcription
        self.analysis = analysis
    }

    /// - Parameters:
    ///   - fileURL: Путь к аудиофайлу на диске.
    ///   - transcriptionMode: Стратегия транскрипции.
    ///   - dryRun: Если true — не записывает изменения на диск.
    /// - Returns: Результат обработки с обновлённой заметкой.
    public func execute(
        fileURL: URL,
        transcriptionMode: TranscriptionMode = .ifMissing,
        dryRun: Bool = false
    ) async throws -> ProcessFileResult {
        // Persists note unless dry-run.
        @Sendable func persist(_ n: CapturedNote) async throws {
            guard !dryRun else { return }
            try await storage.updateNote(n)
        }

        // 1. Ищем существующий sidecar для этого файла
        var note: CapturedNote
        var didTranscribe = false

        if let existing = try await storage.loadNote(matchingAudioPath: fileURL.lastPathComponent) {
            note = existing
        } else {
            if !dryRun {
                note = try await storage.saveRecording(
                    data: Data(contentsOf: fileURL),
                    fileName: fileURL.lastPathComponent,
                    initialText: ""
                )
            } else {
                note = CapturedNote(
                    id: UUID(),
                    createdAt: Date(),
                    text: "",
                    audioPath: fileURL.lastPathComponent,
                    status: .pendingAnalysis
                )
            }
        }

        // 2. Транскрипция
        let shouldTranscribe: Bool
        switch transcriptionMode {
        case .always:   shouldTranscribe = true
        case .ifMissing: shouldTranscribe = note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .skip:     shouldTranscribe = false
        }

        if shouldTranscribe {
            note.text = try await transcription.transcribeFile(at: fileURL)
            didTranscribe = true
            try await persist(note)
        }

        // 3. Анализ
        guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note.status = .failed(reason: "No text to analyze (transcription skipped or empty)", retryable: true)
            try await persist(note)
            return ProcessFileResult(note: note, didTranscribe: didTranscribe)
        }

        do {
            note.card = try await analysis.analyze(text: note.text)
            note.status = .completed
            try await persist(note)
            
        } catch {
            note.status = .failed(reason: error.localizedDescription, retryable: RetryPolicy.isRetryable(error))
            try? await persist(note)
            throw error
        }

        return ProcessFileResult(note: note, didTranscribe: didTranscribe)
    }

}
