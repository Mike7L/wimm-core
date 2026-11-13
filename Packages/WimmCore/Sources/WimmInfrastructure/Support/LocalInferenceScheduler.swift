import Foundation

/// One heavyweight on-device inference at a time. A live session reserves the gaps between
/// preview refreshes too, so a speaker backlog cannot start a long split in that gap.
/// Running work is never interrupted: a completed split must still reach its guarded store.
actor LocalInferenceScheduler {
    static let shared = LocalInferenceScheduler()

    enum Priority: Int, Sendable { case background, file, live }
    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var active: UUID?
    private var waiting: [Waiter] = []
    private var liveSessions: Set<UUID> = []

    func beginLiveSession() -> UUID {
        let id = UUID()
        liveSessions.insert(id)
        return id
    }

    func endLiveSession(_ id: UUID) {
        liveSessions.remove(id)
        startNext()
    }

    func withPermit<T: Sendable>(
        priority: Priority,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let id = try await acquire(priority: priority)
        defer { release(id) }
        try Task.checkCancellation()
        // Keep the caller's task/cancellation. Do not wrap the work in an unstructured Task.
        return try await LocalInferenceExecution.run(priority: priority, operation: operation)
    }

    private func acquire(priority: Priority) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting.append(Waiter(id: id, priority: priority, continuation: continuation))
                startNext()
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        startNext()
    }

    private func startNext() {
        guard active == nil else { return }
        // FIFO within each priority. File runs also wait during live recording.
        let eligible = waiting.indices.filter { liveSessions.isEmpty || waiting[$0].priority == .live }
        guard let index = eligible.max(by: { waiting[$0].priority.rawValue < waiting[$1].priority.rawValue }) else { return }
        let next = waiting.remove(at: index)
        active = next.id
        next.continuation.resume(returning: next.id)
    }

    // Internal diagnostics for deterministic concurrency tests (no model loading required).
    var pendingCount: Int { waiting.count }
    var hasLiveSessions: Bool { !liveSessions.isEmpty }
}

/// Queue order and OS scheduling are separate. Awaiting a low-priority Task can promote it
/// back to the UI caller's priority; a scoped executor instead schedules each async job at
/// the requested Dispatch QoS, without losing task-local values or cancellation.
enum LocalInferenceExecution {
    static func run<T: Sendable>(
        priority: LocalInferenceScheduler.Priority,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        #if os(macOS)
        if #available(macOS 15, *), priority != .live {
            let executor = priority == .background ? InferenceExecutor.background : InferenceExecutor.utility
            return try await withTaskExecutorPreference(executor, operation: operation)
        }
        #endif
        return try await operation()
    }
}

#if os(macOS)
@available(macOS 15, *)
private final class InferenceExecutor: TaskExecutor {
    static let background = InferenceExecutor(qos: .background)
    static let utility = InferenceExecutor(qos: .utility)
    private let queue: DispatchQueue
    private let qos: DispatchQoS

    private init(qos: DispatchQoS) {
        self.qos = qos
        queue = DispatchQueue(label: "app.wimm.local-inference.\(qos.qosClass)", qos: qos,
                              attributes: .concurrent)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async(qos: qos, flags: [.detached, .enforceQoS]) {
            job.runSynchronously(on: executor)
        }
    }
}
#endif
