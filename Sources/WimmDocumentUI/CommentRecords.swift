import Foundation
import WimmInfrastructure

/// Builds root records for `threads.jsonl` with any reaction, not only the
/// six `DocumentReaction` presets: a free emoji is stored as `reaction` with
/// `intent: "custom"`, and the secretary reads it alongside the quote. The
/// file format is the one `docs/Document_Comments.md` describes.
public enum CommentRecords {
    public static func root(in location: DocumentCommentLocation, target: CommentTarget,
                     text: String?, reaction: String?, via: String? = nil, now: Date = Date()) -> DocumentCommentRecord {
        let preset = reaction.flatMap(DocumentReaction.init(emoji:))
        let isReaction = reaction != nil && (text ?? "").isEmpty
        return DocumentCommentRecord(
            id: id(prefix: "c", now: now), kind: isReaction ? .reaction : .comment,
            doc: location.doc, author: DocumentCommentAuthor.owner, at: timestamp(now),
            text: text, section: target.section, heading: target.heading,
            quote: target.selector.quote, prefix: target.selector.prefix, suffix: target.selector.suffix,
            reaction: reaction, intent: reaction == nil ? nil : (preset?.rawValue ?? "custom"), via: via)
    }

    public static func id(prefix: String, now: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        let random = (0..<6).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        return "\(prefix)-\(day.string(from: now))-\(random)"
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
