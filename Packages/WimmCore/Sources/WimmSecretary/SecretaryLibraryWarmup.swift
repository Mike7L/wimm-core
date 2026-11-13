import Foundation
import WimmDomain
import WimmInfrastructure

/// Keep an already-used secretary cache warm during idle time. No model/agent.
/// The disposable CLI owns the large buffers; the application never retains them.
@MainActor public final class SecretaryLibraryWarmup {
    public static let shared = SecretaryLibraryWarmup()
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var warming = false
    private var again = false

    public func start() {
        #if os(macOS)
        guard !StoragePaths.isTestProcess, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: FileStore.sidecarDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule(after: 15) }
        }
        schedule(after: 45)
        #endif
    }

    private func schedule(after seconds: UInt64) {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            await self?.warm()
        }
    }

    private func warm() async {
        #if os(macOS)
        guard !StoragePaths.isTestProcess, !PrivateMode.isEnabled else { return }
        if warming { again = true; return }
        let cache = AgentMarkStore().directory.appendingPathComponent("SecretaryRecallCache/recall-v1.stream")
        guard let changed = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(changed) > 20,
              let cli = SecretaryDispatcher.locateWimmCLI() else { return }
        warming = true
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = cli; process.arguments = ["secretary", "warm"]
            process.qualityOfService = .utility
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() } catch { /* Next explicit prepare rebuilds if needed. */ }
        }.value
        warming = false
        if again { again = false; schedule(after: 15) }
        #endif
    }
}
