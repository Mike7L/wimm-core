import Foundation
import WimmDomain

// Helpers for writing metadata changes
public enum NoteMeta {
    public static func upsertNoteCard(for file: URL, card: NoteCard, lang: String?) {
        let dict: [String: Any] = [
            "schema": card.schema,
            "note_file": card.note_file,
            "lang": (card.lang ?? lang) as Any? ?? NSNull(),
            "title": card.title,
            "summary": card.summary,
            "refined_text": (card.refined_text as Any?) ?? NSNull(),
            "refined_edited_at": card.refined_edited_at?.timeIntervalSinceReferenceDate ?? NSNull(),
            "agent_recommendation": (card.agent_recommendation as Any?) ?? NSNull(),
            "agent_reason": (card.agent_reason as Any?) ?? NSNull(),
            "is_artifact": card.is_artifact,
            "is_liked": card.is_liked,
            "is_insight": card.is_insight,
            "processed_at": card.processed_at?.timeIntervalSinceReferenceDate ?? NSNull(),
            "connected_note_ids": (card.connected_note_ids as Any?) ?? NSNull(),
        ]
        FileStore.upsertMetadata(
            for: file,
            updates: [
                "schema": Schemas.meta,
                "lang": (lang ?? card.lang) as Any? ?? NSNull(),
                "noteCard": dict,
            ])
    }

    /// Mark a note as canceled in metadata
    public static func markAsCanceled(for file: URL) {
        FileStore.upsertMetadata(
            for: file,
            updates: [
                "isCanceled": true,
                "canceledAt": ISO8601.now,
            ])
    }

    /// Remove canceled status from a note
    public static func uncancel(for file: URL) {
        FileStore.upsertMetadata(
            for: file,
            updates: [
                "isCanceled": false
            ])
    }
}
