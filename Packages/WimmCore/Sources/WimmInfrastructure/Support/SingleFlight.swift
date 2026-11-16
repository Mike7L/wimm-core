import Foundation

/// Runs a piece of one-time async work once for all callers. Callers that arrive while it
/// runs wait for the same run; after a success later calls return at once; after a failure
/// the next call starts a fresh run. Actor reentrancy made a plain `if !done { await …;
/// done = true }` run twice when two callers came together (NeuralSpeech, 2026-11-16).
actor SingleFlight {
    private var running: Task<Void, Error>?
    private(set) var isDone = false
    /// How many times the work actually started (diagnostics and tests).
    private(set) var starts = 0

    /// `priority` is the priority of the unstructured task the work runs in, so a caller on
    /// the main actor does not lend the work its user-initiated priority.
    func run(priority: TaskPriority? = nil,
             _ work: @escaping @Sendable () async throws -> Void) async throws {
        if isDone { return }
        if let running {
            try await running.value
            return
        }
        starts += 1
        let task = Task(priority: priority) { try await work() }
        running = task
        do {
            try await task.value
            isDone = true
            running = nil
        } catch {
            running = nil
            throw error
        }
    }
}

/// Waits until either `work` finishes or `isSatisfied` turns true, polled every `poll`.
/// Studio's voice waits for the Parakeet preload this way: the preload sits behind live
/// sessions in `LocalInferenceScheduler`, so during non-stop capture it may never run,
/// although the live transcriber has already loaded the same model.
public enum WarmupOrder {
    public static func wait(
        for work: @escaping @Sendable () async -> Void,
        orUntil isSatisfied: @escaping @Sendable () async -> Bool,
        poll: Duration = .seconds(1)
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask {
                while !Task.isCancelled, !(await isSatisfied()) {
                    do { try await Task.sleep(for: poll) } catch { return }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }
}
