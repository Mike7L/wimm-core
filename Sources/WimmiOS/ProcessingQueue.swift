#if os(iOS)
import Foundation
import UIKit
import WimmDomain

enum ProcessingJobKind: String, Codable {
    /// Transcription with the hear model from Settings, then analysis.
    case transcribe
    /// On-device (Parakeet) transcription, then analysis.
    case transcribeLocal
    /// Cloud transcription (`TranscriptKind.cloud.retranscriptionModel()`), then analysis.
    case transcribeCloud
    /// Analysis of the current text only.
    case analyze
    /// Whatever the note still lacks; nothing if it lacks nothing.
    case auto
}

enum ProcessingOutcome: Equatable {
    case done
    /// The note needed nothing (an `.auto` job on an already processed note).
    case skipped
}

struct ProcessingJob: Identifiable, Codable, Equatable {
    enum State: Codable, Equatable {
        case queued, running, done, skipped
        case failed(String)

        var isActive: Bool { self == .queued || self == .running }
    }

    let id: UUID
    /// Library-relative, so a job survives the App Group container moving.
    let relativePath: String
    let kind: ProcessingJobKind
    var state: State

    var url: URL { FileStore.resolveRelativePath(relativePath) }
}

@MainActor
protocol ProcessingPerformer: AnyObject {
    func perform(_ kind: ProcessingJobKind, url: URL) async throws -> ProcessingOutcome
}

/// The phone's visible queue for cloud transcription and analysis.
///
/// One job at a time, owned by the app rather than a screen, persisted so a
/// queue cut short by iOS resumes on the next launch. Nothing is enqueued
/// without the user asking: each job costs a model call. When the app goes to
/// the background mid-queue it asks iOS for the usual extra half minute; if
/// that runs out the current job goes back to "queued", not "failed".
@MainActor
final class ProcessingQueue: ObservableObject {
    @Published private(set) var jobs: [ProcessingJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false

    weak var performer: ProcessingPerformer?

    private let storeURL: URL?
    private var runTask: Task<Void, Never>?
    private var waiters: [UUID: [CheckedContinuation<ProcessingJob.State, Never>]] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var defaultStoreURL: URL {
        StoragePaths.baseDirectory().appendingPathComponent("processing_queue.json")
    }

    init(storeURL: URL?) {
        self.storeURL = storeURL
        load()
    }

    // MARK: - Reading

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }

    func activeJob(for url: URL) -> ProcessingJob? {
        let path = FileStore.relativePath(for: url)
        return jobs.first { $0.relativePath == path && $0.state.isActive }
    }

    func isActive(_ url: URL) -> Bool { activeJob(for: url) != nil }

    // MARK: - Changing

    /// Adds a job unless the note already has an active one; returns that job's id.
    @discardableResult
    func enqueue(_ url: URL, kind: ProcessingJobKind, atFront: Bool = false) -> UUID {
        if let existing = activeJob(for: url) { return existing.id }
        let job = ProcessingJob(id: UUID(), relativePath: FileStore.relativePath(for: url), kind: kind, state: .queued)
        if atFront, let firstQueued = jobs.firstIndex(where: { $0.state == .queued }) {
            jobs.insert(job, at: firstQueued)
        } else {
            jobs.append(job)
        }
        persist()
        return job.id
    }

    func enqueue(_ urls: [URL], kind: ProcessingJobKind) {
        for url in urls { enqueue(url, kind: kind) }
    }

    /// The note menu's path: jump the queue, run, and report how it ended.
    func run(_ url: URL, kind: ProcessingJobKind) async -> ProcessingJob.State {
        let id = enqueue(url, kind: kind, atFront: true)
        isPaused = false
        start()
        return await waitForEnd(of: id)
    }

    func start() {
        isPaused = false
        persist()
        guard runTask == nil, jobs.contains(where: { $0.state == .queued }) else { return }
        // Set here, not inside the task: the UI must not see "stopped"
        // between the tap and the task's first turn.
        isRunning = true
        runTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Lets the running job finish, then stops.
    func pause() {
        isPaused = true
        persist()
    }

    /// After a relaunch: carry on with a queue the user had started.
    func resumeIfNeeded() {
        if !isPaused { start() }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].state.isActive else { return }
        jobs[index].state = .queued
        start()
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id && $0.state != .running }
        persist()
    }

    func removeQueued() {
        jobs.removeAll { $0.state == .queued }
        persist()
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
        persist()
    }

    // MARK: - Running

    private func drain() async {
        beginBackgroundTime()
        defer {
            isRunning = false
            runTask = nil
            endBackgroundTime()
            persist()
        }

        while !isPaused, !Task.isCancelled, let performer,
              let index = jobs.firstIndex(where: { $0.state == .queued }) {
            jobs[index].state = .running
            let job = jobs[index]
            persist()

            let end: ProcessingJob.State
            do {
                switch try await performer.perform(job.kind, url: job.url) {
                case .done: end = .done
                case .skipped: end = .skipped
                }
            } catch is CancellationError {
                end = .queued
            } catch let error as NoteReprocessingError {
                end = .failed(error.localizedDescription)
                // Every later job would fail the same way.
                if case .missingKey = error { isPaused = true }
            } catch {
                end = .failed(error.localizedDescription)
            }
            if Task.isCancelled {
                // Out of background time: the job did not finish, it did not fail.
                setState(.queued, for: job.id)
                break
            }
            setState(end, for: job.id)
        }
    }

    private func setState(_ state: ProcessingJob.State, for id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].state = state
        }
        persist()
        guard !state.isActive else { return }
        waiters.removeValue(forKey: id)?.forEach { $0.resume(returning: state) }
    }

    private func waitForEnd(of id: UUID) async -> ProcessingJob.State {
        if let job = jobs.first(where: { $0.id == id }), !job.state.isActive { return job.state }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    // MARK: - Background time

    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Wimm processing") { [weak self] in
            Task { @MainActor in
                self?.runTask?.cancel()
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var jobs: [ProcessingJob]
        var isPaused: Bool
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // A job that was running when the app died never finished.
        jobs = stored.jobs.map { job in
            var job = job
            if job.state == .running { job.state = .queued }
            return job
        }
        isPaused = stored.isPaused
    }

    private func persist() {
        guard let storeURL else { return }
        let stored = Stored(jobs: jobs, isPaused: isPaused)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
#endif
