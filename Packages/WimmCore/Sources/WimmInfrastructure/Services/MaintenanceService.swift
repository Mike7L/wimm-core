import Foundation
import WimmDomain

@MainActor
public final class MaintenanceService {
    public init() {}

    public func countMissingNoteCards() async -> Int {
        await NoteProcessor.shared.countMissingNoteCards()
    }

    public func retryMissingNoteCards(
        batchSize: Int = 50,
        progress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> (success: Int, failed: Int) {
        await NoteProcessor.shared.retryMissingNoteCards(batchSize: batchSize, progress: progress)
    }
}
