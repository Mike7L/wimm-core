import Foundation
import WimmDomain

// Feature flag to enable SwiftData-backed note metadata storage.
public enum SwiftDataCfg {
    /// Enable SwiftData storage layer. Can be toggled via UserDefaults key or env var.
    /// Env var has priority. Defaults to false.
    public static var enabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["WIMM_SWIFTDATA"], !raw.isEmpty {
            return raw == "1" || raw.lowercased() == "true"
        }
        return UserDefaults.standard.bool(forKey: DefaultsKey.swiftDataEnabled)
    }
}

#if SWIFTDATA_ENABLED
import SwiftData

// Shared SwiftData stack. One container for the app; pass ModelContext into Core layer when needed.
public enum SwiftDataStack {
    private static let storeName = "WimmStore"
    public nonisolated(unsafe) static var isPersistentStoreAvailable = true
    public nonisolated(unsafe) static var didResetStore = false

    public static let shared: ModelContainer = {
        let models: [any PersistentModel.Type] = [
            NoteMetaEntity.self,
            AgentMessageEntity.self
        ]
        let schema = Schema(models)
        // `.none` is load-bearing. The default (`.automatic`) turns on CloudKit
        // mirroring whenever the app carries an iCloud entitlement — which the
        // signed store build does, for CloudSync. This schema is not CloudKit-
        // compatible (non-optional attributes, unique ids), so every store,
        // including the in-memory fallback, failed to load and the app hit the
        // fatalError below on launch. Notes sync through CloudSync, not SwiftData.
        let config = ModelConfiguration(storeName, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            log("SwiftData container init failed: \(error)")
            let paths = persistentStoreCandidateURLs().map { $0.path }.joined(separator: " | ")
            log("SwiftData store candidates: \(paths)")
            if resetPersistentStore() {
                didResetStore = true
            }
            do {
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                log("SwiftData container init failed after reset: \(error). Falling back to in-memory store.")
                isPersistentStoreAvailable = false
                let memConfig = ModelConfiguration("InMemory", isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                if let mem = try? ModelContainer(for: schema, configurations: memConfig) {
                    return mem
                }
                fatalError("Failed to initialize SwiftData in-memory container: \(error)")
            }
        }
    }()

    /// Convenience to create an in-memory container (used by tests)
    public static func inMemory() throws -> ModelContainer {
        let models: [any PersistentModel.Type] = [
            NoteMetaEntity.self,
            AgentMessageEntity.self
        ]
        let schema = Schema(models)
        let cfg = ModelConfiguration("InMemory", isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: cfg)
    }

    private static func resetPersistentStore() -> Bool {
        var removedAny = false
        let fm = FileManager.default
        for url in persistentStoreCandidateURLs() {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    removedAny = true
                    log("Removed SwiftData store file: \(url.path)")
                } catch {
                    log("Failed to remove SwiftData store file at \(url.path): \(error)")
                }
            }
        }
        return removedAny
    }

    private static func persistentStoreCandidateURLs() -> [URL] {
        var urls: [URL] = []
        let base = FileStore.baseDirectory()
        urls.append(base.appendingPathComponent("\(storeName).sqlite"))
        urls.append(base.appendingPathComponent("\(storeName).store"))
        urls.append(base.appendingPathComponent("SwiftData", isDirectory: true).appendingPathComponent("\(storeName).sqlite"))
        urls.append(base.appendingPathComponent("SwiftData", isDirectory: true).appendingPathComponent("\(storeName).store"))

        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let bundleId = Bundle.main.bundleIdentifier ?? "Wimm"
            let legacyDir = appSupport.appendingPathComponent(bundleId, isDirectory: true)
            urls.append(legacyDir.appendingPathComponent("\(storeName).sqlite"))
            urls.append(legacyDir.appendingPathComponent("\(storeName).store"))
        }

        var expanded: [URL] = []
        for url in urls {
            expanded.append(url)
            expanded.append(URL(fileURLWithPath: url.path + "-wal"))
            expanded.append(URL(fileURLWithPath: url.path + "-shm"))
        }
        return expanded
    }
}

/// Provide a ModelContext to non-UI code.
public enum SwiftDataContextProvider {
    public static func newContext() -> ModelContext { ModelContext(SwiftDataStack.shared) }
}
#endif
