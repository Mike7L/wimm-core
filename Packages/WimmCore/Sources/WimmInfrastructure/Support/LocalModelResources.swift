import Foundation
import Dispatch

/// Idle eviction always takes the same permit as inference/loading. Live sessions reserve
/// the permit between refreshes, and a completed split is never interrupted or discarded.
public enum LocalModelResources {
    // Measured on M1: warm model reload ~54 s for only 18–28 MB returned.
    // Keep normal sessions warm. An explicit diagnostic override can opt into idle trimming.
    static let registry: IdleModelRegistry = {
        let requested = ProcessInfo.processInfo.environment["WIMM_MODEL_IDLE_SECONDS"].flatMap(Double.init)
        let enabled = requested.map { $0.isFinite && $0 >= 60 } ?? false
        return IdleModelRegistry(idleSeconds: enabled ? requested! : 300, automaticallyTrim: enabled)
    }()
    static func used(_ id: String, release: @escaping @Sendable () async -> Void) async {
        _ = ModelMemoryPressure.shared
        await registry.record(id, release: release)
    }
    static func touch(_ id: String) async { await registry.touch(id) }
    public static func releaseUnused(force: Bool = false) async throws {
        try await LocalInferenceScheduler.shared.withPermit(priority: force ? .live : .background) {
            let protectLiveASR = await LocalInferenceScheduler.shared.hasLiveSessions
            await registry.evict(force: force, protectedPrefix: protectLiveASR ? "parakeet:" : nil)
        }
    }
    public static func loadedModels() async -> [String] { await registry.ids }
}

actor IdleModelRegistry {
    struct Entry { var used: Date; let release: @Sendable () async -> Void }
    private var entries: [String: Entry] = [:]
    private var timer: Task<Void, Never>?
    let idleSeconds: TimeInterval
    private let automaticallyTrim: Bool
    init(idleSeconds: TimeInterval = 300, automaticallyTrim: Bool = true) {
        self.idleSeconds = idleSeconds; self.automaticallyTrim = automaticallyTrim
    }
    var ids: [String] { entries.keys.sorted() }
    func record(_ id: String, at date: Date = Date(), release: @escaping @Sendable () async -> Void) {
        entries[id] = Entry(used: date, release: release)
        schedule()
    }
    func touch(_ id: String, at date: Date = Date()) {
        entries[id]?.used = date
        schedule()
    }
    /// Called while the global inference permit is held, including awaits in release callbacks.
    func evict(force: Bool, now: Date = Date(), protectedPrefix: String? = nil) async {
        let expired = entries.filter {
            if let protectedPrefix, $0.key.hasPrefix(protectedPrefix) { return false }
            return force || now.timeIntervalSince($0.value.used) >= idleSeconds
        }
        for (id, entry) in expired {
            entries.removeValue(forKey: id)
            await entry.release()
        }
        schedule()
    }
    private func schedule() {
        timer?.cancel(); timer = nil
        guard automaticallyTrim, let oldest = entries.values.map(\.used).min() else { return }
        let delay = max(1, idleSeconds - Date().timeIntervalSince(oldest))
        timer = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            try? await LocalModelResources.releaseUnused()
        }
    }
}

private final class ModelMemoryPressure: @unchecked Sendable {
    static let shared = ModelMemoryPressure()
    private let source: DispatchSourceMemoryPressure
    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { try? await LocalModelResources.releaseUnused(force: true) }
        }
        source.resume()
    }
}
