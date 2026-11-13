import Foundation
import WimmDomain

/// A user's delete, the same on the Mac and on iOS: the note's files go to
/// `Trash/` (with the trash marker, `RecordingTrashSupport`), then its
/// tombstone is queued so the other devices drop it too. The local delete
/// never waits on iCloud: the tombstone sits in the sync ledger as
/// `pendingDelete` and later syncs retry it when offline. A delete that came
/// from another device uses `RecordingTrashSupport.moveToTrash` directly.
/// `async` so the file moves run off the caller's (main) actor.
public enum NoteTrash {
    @discardableResult
    public static func moveToTrash(_ file: URL, cloudSync: CloudRecordingSyncService?) async -> URL? {
        let trashed = RecordingTrashSupport.moveToTrash(file: file, onFailure: { source, error in
            log("Failed to move \(source.lastPathComponent) to trash: \(error)")
        })
        if let trashed, let cloudSync {
            Task.detached(priority: .utility) {
                do {
                    try await cloudSync.markTrashed(trashedURL: trashed, originalURL: file)
                } catch {
                    log("[CloudSync] could not queue delete of \(file.lastPathComponent): \(error)")
                }
            }
        }
        return trashed
    }
}
