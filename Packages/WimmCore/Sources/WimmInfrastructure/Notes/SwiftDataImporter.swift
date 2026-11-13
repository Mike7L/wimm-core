import Foundation
import WimmDomain

#if SWIFTDATA_ENABLED
import SwiftData

public enum SwiftDataImporter {
    public static func run(context: ModelContext, backupJSON: URL? = nil) throws {
        let recs = FileStore.listAllRecordingFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }
        let haveNoteIds = try Set(context.fetch(FetchDescriptor<NoteMetaEntity>()).map { $0.id })

        for url in recs {
            let id = url.lastPathComponent
            if haveNoteIds.contains(id) { continue }

            let metaURL = FileStore.metadataURL(forRecordingURL: url)
            var title = url.deletingPathExtension().lastPathComponent
            var isLiked = false
            var createdAt = (try? FileStore.fileCreationDate(url)) ?? Date()
            var updatedAt = createdAt

            if let data = try? Data(contentsOf: metaURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = (json["noteCard"] as? [String: Any])?["title"] as? String, !t.isEmpty {
                    title = t
                }
                if let card = json["noteCard"] as? [String: Any], let liked = card["is_liked"] as? Bool {
                    isLiked = liked
                }
                if let createdStr = json["createdAt"] as? String, let d = ISO8601.date(from: createdStr) {
                    createdAt = d
                }
                if let updatedStr = json["updatedAt"] as? String, let d = ISO8601.date(from: updatedStr) {
                    updatedAt = d
                }
            }

            context.insert(NoteMetaEntity(id: id, title: title, path: url.path, tags: [], isLiked: isLiked, createdAt: createdAt, updatedAt: updatedAt))
        }

        try context.save()
    }
}
#else
public enum SwiftDataImporter {
    public static func run(context: Any, backupJSON: URL? = nil) throws {}
}
#endif
