import Foundation

/// Изолированная очередь обработки.
///
/// Работает по принципу "сканирование и исполнение" (Scan & Exec).
/// Гарантирует, что только одна операция модификации происходит в каждый момент времени.
public actor QueueSupervisor {
    private let storage: StoragePort
    private let analysis: AnalysisPort
    private let workflow: ProcessingWorkflow

    // Статус: работает или остановлен.
    public private(set) var isProcessing: Bool = false

    // Подписка на прогресс (для TUI).
    public typealias ProgressHandler = @Sendable (Int, Int) async -> Void
    private var onProgress: ProgressHandler?

    public init(storage: StoragePort, analysis: AnalysisPort) {
        self.storage = storage
        self.analysis = analysis
        self.workflow = ProcessingWorkflow(storage: storage, analysis: analysis)
    }
    
    public func setProgressHandler(_ handler: @escaping ProgressHandler) {
        self.onProgress = handler
    }

    /// Возвращает список задач, которые будут обработаны, без изменений на диске.
    public func previewProcessQueue(limit: Int? = nil) async throws -> [UUID] {
        try await pendingNotes(limit: limit).map(\.id)
    }

    /// Запустить фоновую обработку всей очереди.
    /// - Returns: количество успешно обработанных задач.
    public func processQueue(limit: Int? = nil) async throws -> Int {
        guard !isProcessing else { return 0 }
        isProcessing = true
        defer { isProcessing = false }
        return try await workflow.run(notes: pendingNotes(limit: limit), onProgress: onProgress)
    }
    
    /// Добавить задачу в очередь явно (например, при создании новой заметки).
    /// В MVP это просто сигнал перечитать диск, т.к. очередь == диск.
    public func notifyNewTask() async {
        if !isProcessing {
            _ = try? await processQueue()
        }
    }

    /// Переводит failed задачи обратно в pending и запускает обработку.
    /// - Parameters:
    ///   - includeNonRetryable: если true, ретраит все failed, иначе только retryable
    ///   - idPrefix: если задан, ретраит только заметку с данным UUID-префиксом
    /// - Returns: кортеж (retried, processed)
    public func retryFailedTasks(
        includeNonRetryable: Bool = false,
        idPrefix: String? = nil
    ) async throws -> (retried: Int, processed: Int) {
        let candidates = try await failedCandidates(includeNonRetryable: includeNonRetryable, idPrefix: idPrefix)
        for note in candidates {
            var updated = note
            updated.status = .pendingAnalysis
            try await storage.updateNote(updated)
        }
        let processed = try await processQueue()
        return (candidates.count, processed)
    }

    /// Возвращает список failed задач, подходящих под условия ретрая, без изменений на диске.
    public func previewRetryFailedTasks(
        includeNonRetryable: Bool = false,
        idPrefix: String? = nil
    ) async throws -> [UUID] {
        try await failedCandidates(includeNonRetryable: includeNonRetryable, idPrefix: idPrefix).map(\.id)
    }

    // MARK: - Helpers

    private func pendingNotes(limit: Int? = nil) async throws -> [CapturedNote] {
        let all = try await storage.loadAll()
        let pending = all.filter { $0.status == .pendingAnalysis }
        guard let limit, limit > 0 else { return pending }
        return Array(pending.prefix(limit))
    }

    private func failedCandidates(includeNonRetryable: Bool, idPrefix: String?) async throws -> [CapturedNote] {
        let notes = try await storage.loadAll()
        let prefix = idPrefix?.lowercased()
        return notes.filter { note in
            guard case let .failed(_, retryable) = note.status else { return false }
            if let prefix {
                // Explicit prefix targets any failed note with that id, regardless of retryable flag.
                return note.id.uuidString.lowercased().hasPrefix(prefix)
            }
            return includeNonRetryable || retryable
        }
    }

}
