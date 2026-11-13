import Foundation

public enum HUDSnapshotService {
    public static func makeSnapshot(
        notes: [CapturedNote],
        queue: QueueStatusSnapshot,
        generatedAt: Date = Date(),
        recentLimit: Int = 8
    ) -> HUDSnapshot {
        let sorted = notes.sorted { $0.createdAt > $1.createdAt }
        let preferredRecent = hudPreferredRecentNotes(from: sorted, limit: recentLimit)
        let rows = preferredRecent.map { note in
            HUDSnapshot.NoteRow(
                shortID: note.shortID,
                createdAt: note.createdAt,
                statusLabel: hudStatusLabel(for: note.status),
                title: hudDisplayTitle(for: note)
            )
        }

        return HUDSnapshot(
            generatedAt: generatedAt,
            total: notes.count,
            pending: queue.pendingCount,
            completed: queue.completedCount,
            failedRetryable: queue.failedRetryableCount,
            failedNonRetryable: queue.failedNonRetryableCount,
            recent: rows
        )
    }
}
