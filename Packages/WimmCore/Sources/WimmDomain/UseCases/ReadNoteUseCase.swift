import Foundation

public struct ReadNoteUseCase: Sendable {
    private let storage: StoragePort

    public init(storage: StoragePort) {
        self.storage = storage
    }

    public func execute(id: UUID) async throws -> CapturedNote? {
        try await storage.loadAll().first(where: { $0.id == id })
    }

    public func execute(idPrefix: String) async throws -> CapturedNote? {
        let prefix = idPrefix.lowercased()
        return try await storage.loadAll().first {
            $0.id.uuidString.lowercased().hasPrefix(prefix)
        }
    }
}
