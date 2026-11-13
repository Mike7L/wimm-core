import Foundation

public struct ListNotesUseCase: Sendable {
    private let storage: StoragePort

    public init(storage: StoragePort) {
        self.storage = storage
    }

    public func execute() async throws -> [CapturedNote] {
        // storage.loadAll() guarantees createdAt-desc order; no re-sort needed
        try await storage.loadAll()
    }
}
