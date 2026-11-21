import Foundation
import WimmDomain
import WimmInfrastructure
import WimmSecretary

/// The whole note library for Alyona's `search_notes`, loaded the way
/// `wimm-cli mcp` loads it: changed notes are built by `wimm-cli mcp-build`
/// in a child process, so the parsing garbage leaves with it, and a disk cache
/// of its own (`AgentState/VikRecallCache`) makes a cold start a restore.
/// The text (~150–190 MB) is dropped after `idleSeconds` without a search.
/// Without an installed CLI there is no search: building in Studio's own
/// process would keep that garbage for the life of the app.
actor VikLibrary {
    private let source: LibraryRecallSource?
    private let idleSeconds: TimeInterval
    private var sweeper: Task<Void, Never>?

    init(cli: URL? = StoragePaths.isTestProcess ? nil : SecretaryDispatcher.locateWimmCLI(),
         idleSeconds: TimeInterval = 15 * 60) {
        self.idleSeconds = idleSeconds
        source = cli.map {
            LibraryRecallSource(buildMode: .subprocess(executable: $0, arguments: ["mcp-build"]),
                                cacheDirectory: AgentMarkStore().directory.appendingPathComponent("VikRecallCache"))
        }
    }

    var isAvailable: Bool { source != nil }

    /// Nil without a CLI. Concurrent callers share one load.
    func load() async -> RecallLibrary? {
        guard let source else { return nil }
        let started = Date()
        let library = await source.load()
        log("[Vik] library_load_ms=\(Int(Date().timeIntervalSince(started) * 1000)) notes=\(library.count) restored=\(await source.restoredFromDisk)")
        scheduleRelease()
        return library
    }

    /// Starts a load ahead of a likely search (the address was heard); no model call.
    nonisolated func prewarm() {
        Task { _ = await self.load() }
    }

    private func scheduleRelease() {
        guard sweeper == nil, let source else { return }
        let interval = idleSeconds
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(30, interval / 4)))
                if await source.releaseIfIdle(after: interval) {
                    log("[Vik] library_released")
                    await self?.stopSweeping()
                    return
                }
            }
        }
    }

    private func stopSweeping() { sweeper = nil }
}
