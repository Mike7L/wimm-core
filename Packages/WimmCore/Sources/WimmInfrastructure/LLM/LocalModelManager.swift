import Foundation

#if ENABLE_LOCAL_AI

public protocol LocalModelBackend: Sendable {
    func isModelLoaded(identifier: String) async -> Bool
    func unloadModel() async
    func loadModel(identifier: String) async throws
    func generate(prompt: String, modelIdentifier: String) async throws -> String
}

private enum LocalModelSupport {
    private static let lock = NSLock()
    // Lock-protected; nonisolated(unsafe) is the established escape hatch
    // for this pattern (see MiniAudio.pathLocks).
    private nonisolated(unsafe) static var backend: LocalModelBackend?

    static func register(_ newBackend: LocalModelBackend?) {
        lock.lock()
        backend = newBackend
        lock.unlock()
    }

    static func resolve() -> LocalModelBackend? {
        lock.lock()
        let value = backend
        lock.unlock()
        return value
    }

    static var isAvailable: Bool {
        lock.lock()
        let available = backend != nil
        lock.unlock()
        return available
    }
}

public actor LocalModelManager {
    public static let shared = LocalModelManager()
    private var loadTasks: [String: Task<Void, Error>] = [:]

    public static func registerBackend(_ backend: LocalModelBackend?) {
        LocalModelSupport.register(backend)
    }

    public static var isAvailable: Bool { LocalModelSupport.isAvailable }

    public static var isEnabled: Bool {
        guard isAvailable else { return false }
        let env = ProcessInfo.processInfo.environment
        if let raw = env["WIMM_DISABLE_LOCAL_AI"], isTruthy(raw) {
            return false
        }
        if let raw = env["ENABLE_LOCAL_AI"] {
            return isTruthy(raw)
        }
        return true
    }

    public static func normalizeIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("local/") {
            return String(trimmed.dropFirst("local/".count))
        }
        return trimmed
    }
    
    private init() {}

    public func isModelLoaded(identifier: String) async -> Bool {
        guard let backend = LocalModelSupport.resolve(), Self.isEnabled else { return false }
        return await backend.isModelLoaded(identifier: identifier)
    }

    public func unloadModel() async {
        guard let backend = LocalModelSupport.resolve(), Self.isEnabled else { return }
        await backend.unloadModel()
    }
    
    public func loadModel(identifier: String) async throws {
        guard let backend = LocalModelSupport.resolve(), Self.isEnabled else {
            throw LocalModelError.localAISupportDisabled
        }
        if await backend.isModelLoaded(identifier: identifier) {
            return
        }

        let normalized = Self.normalizeIdentifier(identifier)
        if let task = loadTasks[normalized] {
            try await task.value
            return
        }

        let task = Task {
            try await backend.loadModel(identifier: normalized)
        }
        loadTasks[normalized] = task
        defer { loadTasks[normalized] = nil }
        try await task.value
    }
    
    public func generate(prompt: String, modelIdentifier: String) async throws -> String {
        guard let backend = LocalModelSupport.resolve(), Self.isEnabled else {
            throw LocalModelError.localAISupportDisabled
        }
        return try await backend.generate(prompt: prompt, modelIdentifier: modelIdentifier)
    }

    private static func isTruthy(_ raw: String) -> Bool {
        ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

public enum LocalModelError: Error {
    case localAISupportDisabled
    case modelNotFound(String)
    case loadingFailed(String)
}

#endif

