import Foundation

public struct QueueStatusSnapshot: Sendable, Equatable {
    public struct FailedItem: Sendable, Equatable {
        public let id: UUID
        public let createdAt: Date
        public let reason: String
        public let retryable: Bool

        public init(id: UUID, createdAt: Date, reason: String, retryable: Bool) {
            self.id = id
            self.createdAt = createdAt
            self.reason = reason
            self.retryable = retryable
        }
    }

    public let pendingCount: Int
    public let completedCount: Int
    public let failedRetryableCount: Int
    public let failedNonRetryableCount: Int
    public let failedItems: [FailedItem]

    public init(
        pendingCount: Int,
        completedCount: Int,
        failedRetryableCount: Int,
        failedNonRetryableCount: Int,
        failedItems: [FailedItem]
    ) {
        self.pendingCount = pendingCount
        self.completedCount = completedCount
        self.failedRetryableCount = failedRetryableCount
        self.failedNonRetryableCount = failedNonRetryableCount
        self.failedItems = failedItems
    }
}

public struct GetQueueStatusUseCase: Sendable {
    private let storage: StoragePort

    public init(storage: StoragePort) {
        self.storage = storage
    }

    public func execute() async throws -> QueueStatusSnapshot {
        let notes = try await storage.loadAll()

        var pending = 0
        var completed = 0
        var failedRetryable = 0
        var failedNonRetryable = 0
        var failedItems: [QueueStatusSnapshot.FailedItem] = []

        for note in notes {
            switch note.status {
            case .pendingAnalysis:
                pending += 1
            case .completed:
                completed += 1
            case let .failed(reason, retryable):
                if retryable { failedRetryable += 1 } else { failedNonRetryable += 1 }
                failedItems.append(.init(id: note.id, createdAt: note.createdAt,
                                         reason: reason, retryable: retryable))
            }
        }

        // loadAll() already returns notes sorted createdAt-desc; failedItems preserves that order.
        return QueueStatusSnapshot(
            pendingCount: pending,
            completedCount: completed,
            failedRetryableCount: failedRetryable,
            failedNonRetryableCount: failedNonRetryable,
            failedItems: failedItems
        )
    }
}
