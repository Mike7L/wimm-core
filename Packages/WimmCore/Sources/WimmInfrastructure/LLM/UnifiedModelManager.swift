import Foundation

public protocol ModelJobHandler: Sendable {
    func process(job: ModelJob, progress: @Sendable @escaping (Double) -> Void) async throws
        -> String
}

@MainActor
public class UnifiedModelManager: ObservableObject {
    public struct QueueSnapshot {
        public let queued: Int
        public let processing: Int
        public let activeJob: ModelJob?
        public let nextJob: ModelJob?
    }

    public static let shared = UnifiedModelManager()

    @Published public var jobs: [ModelJob] = []

    // Handlers for different model types
    private var handlers: [ModelType: ModelJobHandler] = [:]

    // Processing state
    private var processingCounts: [ModelType: Int] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentJobsPerType = 1
    private let maxFinishedHistoryPerType: Int
    private var retainedResults: Set<UUID> = []
    private var resultWaiters: [UUID: Int] = [:]

    // Internal initializer also gives tests an isolated queue, without touching the singleton.
    init(maxFinishedHistoryPerType: Int = 200) {
        self.maxFinishedHistoryPerType = max(0, maxFinishedHistoryPerType)
    }

    public func register(handler: ModelJobHandler, for type: ModelType) {
        handlers[type] = handler
    }

    /// Use `retainResult` for front-loaded batches: waitForCompletion consumes that reservation.
    /// Release unvisited reservations with releaseResults when abandoning the batch.
    @discardableResult
    public func submit(
        type: ModelType, input: String, priority: ModelPriority = .normal, engine: String,
        context: [String: String]? = nil, retainResult: Bool = false
    ) -> UUID {
        let job = ModelJob(
            type: type,
            input: input,
            priority: priority,
            status: .queued,
            engine: engine,
            context: context
        )

        // Insert based on priority
        // For now just append, processNext will sort/pick
        jobs.append(job)
        if retainResult { retainedResults.insert(job.id) }

        processNext(for: type)
        return job.id
    }

    /// Add a manually-managed job that is considered processing immediately.
    /// Intended for long-running flows that handle their own execution lifecycle
    /// (e.g. streaming chat/wikification) but should still be visible in queue UI.
    @discardableResult
    public func beginManualJob(
        type: ModelType,
        input: String,
        priority: ModelPriority = .normal,
        engine: String,
        context: [String: String]? = nil
    ) -> UUID {
        let job = ModelJob(
            type: type,
            input: input,
            priority: priority,
            status: .processing,
            engine: engine,
            context: context
        )
        jobs.append(job)
        return job.id
    }

    public func completeManualJob(jobId: UUID, error: String? = nil, output: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].output = output
        if let error, !error.isEmpty {
            jobs[index].status = .failed(error)
        } else {
            jobs[index].status = .completed
        }
        pruneFinishedHistory(for: jobs[index].type)
    }

    /// Await an already-submitted job until it reaches a terminal state.
    /// Lets bulk callers front-load a whole batch via `submit` (so queue UI sees
    /// the real total immediately) and then await the jobs one by one. Those submissions
    /// must use `retainResult: true`; ordinary completed history is limited to 200 per type.
    public func waitForCompletion(
        jobId: UUID, progress: ((Double) -> Void)? = nil
    ) async throws -> String {
        resultWaiters[jobId, default: 0] += 1
        defer {
            resultWaiters[jobId, default: 1] -= 1
            if resultWaiters[jobId] == 0 { resultWaiters.removeValue(forKey: jobId) }
            releaseResults(for: [jobId])
        }
        // Poll for completion (simple implementation for now vs complex observers)
        // Ideally we would use async stream or continuations map
        while true {
            try Task.checkCancellation()
            guard let job = getJob(id: jobId) else {
                throw NSError(
                    domain: "UnifiedModelManager", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Job lost"])
            }

            if let p = job.progress, let progress = progress {
                progress(p)
            }

            if case .completed = job.status {
                return job.output ?? ""
            }
            if case .failed(let msg) = job.status {
                throw NSError(
                    domain: "UnifiedModelManager", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: msg])
            }

            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms poll
        }
    }

    /// A batch submitted with `retainResult: true` owns its results until each wait ends.
    /// Release unvisited results too when abandoning a batch. Ordinary fire-and-forget jobs
    /// use the bounded UI history; they do not reserve potentially large outputs forever.
    public func releaseResults(for jobIds: [UUID]) {
        let released = Set(jobIds)
        let types = Set(jobs.lazy.filter { released.contains($0.id) }.map(\.type))
        retainedResults.subtract(released)
        for type in types { pruneFinishedHistory(for: type) }
    }

    public func cancel(jobId: UUID) {
        if let task = runningTasks[jobId] {
            task.cancel()
        }
        if let index = jobs.firstIndex(where: { $0.id == jobId }) {
            var job = jobs[index]
            if job.status == .processing || job.status == .queued {
                job.status = .failed("Cancelled")
                jobs[index] = job
                pruneFinishedHistory(for: job.type)
            }
        }
    }

    public func getJob(id: UUID) -> ModelJob? {
        jobs.first(where: { $0.id == id })
    }

    public func queueSnapshot(for type: ModelType) -> QueueSnapshot {
        let typeJobs = jobs.filter { $0.type == type }
        let processingJobs = typeJobs
            .filter { $0.status == .processing }
            .sorted { $0.submittedAt < $1.submittedAt }
        let queuedJobs = typeJobs
            .filter { $0.status == .queued }
            .sorted {
                if $0.priority == $1.priority {
                    return $0.submittedAt < $1.submittedAt
                }
                return $0.priority > $1.priority
            }

        return QueueSnapshot(
            queued: queuedJobs.count,
            processing: processingJobs.count,
            activeJob: processingJobs.first,
            nextJob: queuedJobs.first
        )
    }

    private func processNext(for type: ModelType) {
        if isPaused(type) { return }
        let currentProcessing = processingCounts[type] ?? 0
        guard currentProcessing < maxConcurrentJobsPerType else { return }

        // Pick highest priority queued job
        let queue = jobs.filter { $0.type == type && $0.status == .queued }
            .sorted { $0.priority > $1.priority }  // High priority first

        guard let nextJob = queue.first else { return }
        guard let index = jobs.firstIndex(where: { $0.id == nextJob.id }) else { return }

        // Update status
        jobs[index].status = .processing
        processingCounts[type] = currentProcessing + 1

        let jobToRun = jobs[index]
        let handler = handlers[type]

        let task = Task.detached {
            var resultStatus: ModelJobStatus = .failed("Job not executed")
            var outputResult: String?
            do {
                try await LLMQueueContext.$inUnifiedQueue.withValue(true) {
                    if let handler = handler {
                        let result = try await handler.process(job: jobToRun) { pct in
                            Task { @MainActor in
                                self.updateProgress(jobId: jobToRun.id, progress: pct)
                            }
                        }
                        outputResult = result
                        resultStatus = .completed
                    } else {
                        resultStatus = .failed("No handler registered for \(type.rawValue)")
                    }
                }
            } catch is CancellationError {
                resultStatus = .failed("Cancelled")
            } catch {
                resultStatus = .failed(error.localizedDescription)
            }

            await self.finish(jobId: jobToRun.id, status: resultStatus, output: outputResult)
        }
        runningTasks[jobToRun.id] = task
    }

    public func updateProgress(jobId: UUID, progress: Double) {
        if let index = jobs.firstIndex(where: { $0.id == jobId }) {
            jobs[index].progress = progress
        }
    }

    private func finish(jobId: UUID, status: ModelJobStatus, output: String?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        let job = jobs[index]
        jobs[index].status = status
        jobs[index].output = output

        runningTasks.removeValue(forKey: jobId)

        let count = processingCounts[job.type] ?? 1
        processingCounts[job.type] = max(0, count - 1)

        // Trigger next
        processNext(for: job.type)
        pruneFinishedHistory(for: job.type)
    }

    private func pruneFinishedHistory(for type: ModelType) {
        let terminalIndices = jobs.indices.filter { idx in
            let job = jobs[idx]
            guard job.type == type else { return false }
            guard isTerminal(job.status) else { return false }
            return !isResultProtected(job.id)
        }

        let overflow = terminalIndices.count - maxFinishedHistoryPerType
        guard overflow > 0 else { return }

        // Remove oldest terminal jobs first; keep newest history.
        let idsToRemove = Set(terminalIndices
            .sorted { jobs[$0].submittedAt < jobs[$1].submittedAt }
            .prefix(overflow)
            .map { jobs[$0].id })
        jobs.removeAll { idsToRemove.contains($0.id) }
    }

    private func isResultProtected(_ id: UUID) -> Bool {
        retainedResults.contains(id) || resultWaiters[id] != nil || runningTasks[id] != nil
    }

    private func isTerminal(_ status: ModelJobStatus) -> Bool {
        switch status {
        case .completed, .failed:
            return true
        case .queued, .processing:
            return false
        }
    }

    // Pause state per model type
    // We use UserDefault backing for persistence if needed, or just memory?
    // Previous managers used UserDefaults. Let's replicate simple memory + notification for now?
    // Or better, just memory for simplicty unless persistence is critical.
    @Published public private(set) var pausedTypes: Set<ModelType> = []

    public func setPaused(_ paused: Bool, for type: ModelType) {
        if paused {
            pausedTypes.insert(type)
        } else {
            pausedTypes.remove(type)
            processNext(for: type)
        }
    }

    public func isPaused(_ type: ModelType) -> Bool {
        pausedTypes.contains(type)
    }

    // Debug helper
    public func clearCompleted() {
        jobs.removeAll {
            isTerminal($0.status) && !isResultProtected($0.id)
        }
    }

    public func cancelAll(for type: ModelType) {
        // Cancel running tasks for this type
        let processingIds = jobs.filter { $0.type == type && $0.status == .processing }.map { $0.id }
        for id in processingIds {
            runningTasks[id]?.cancel()
        }
        // Mark all active jobs as cancelled
        for index in jobs.indices where jobs[index].type == type {
            if jobs[index].status == .processing || jobs[index].status == .queued {
                jobs[index].status = .failed("Cancelled")
            }
        }
        pruneFinishedHistory(for: type)
    }
}
