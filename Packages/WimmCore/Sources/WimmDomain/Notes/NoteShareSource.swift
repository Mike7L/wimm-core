import Foundation

/// Where an item shared into Wimm from another app came from, and when the
/// original was made. Stored in the `.meta.json` sidecar under "shareSource":
///
///     {"app": "Voice Memos", "url": "https://…", "fileName": "Kitchen.m4a",
///      "title": "…", "date": "2026-10-12T08:31:00Z", "dateBasis": "embedded",
///      "sharedAt": "2026-10-19T10:02:11Z"}
///
/// Every field is optional. `date` is the original's date, never the import
/// time: `dateBasis` says whether it was read from the file's own metadata
/// ("embedded": audio creation date, EXIF, PDF info) or from its file-system
/// dates ("file"). The note's own timestamp stays the import time — this is
/// shown, it does not reorder the journal.
public struct NoteShareSource: Equatable, Sendable {
    public static let metadataKey = "shareSource"

    /// Keys of the `<file>.share.json` the share extension drops next to each
    /// inbox file. The extension cannot link this module and spells them out.
    public enum InboxKey {
        public static let fileName = "fileName"
        public static let title = "title"
        public static let url = "url"
        public static let fileCreated = "fileCreated"
        public static let fileModified = "fileModified"
        public static let sharedAt = "sharedAt"
    }

    public static let inboxSidecarSuffix = ".share.json"

    public enum DateBasis: String, Sendable {
        case embedded
        case file
    }

    public var app: String?
    public var url: URL?
    public var fileName: String?
    public var title: String?
    public var date: Date?
    public var dateBasis: DateBasis?
    public var sharedAt: Date?

    public init(
        app: String? = nil,
        url: URL? = nil,
        fileName: String? = nil,
        title: String? = nil,
        date: Date? = nil,
        dateBasis: DateBasis? = nil,
        sharedAt: Date? = nil
    ) {
        self.app = app
        self.url = url
        self.fileName = fileName
        self.title = title
        self.date = date
        self.dateBasis = dateBasis
        self.sharedAt = sharedAt
    }

    /// Builds the source from the extension's inbox sidecar plus what the app
    /// read from the file itself. Embedded metadata beats file-system dates.
    /// File dates within a minute of the share are the provider's temp copy,
    /// not the original, and are dropped.
    public init(inbox: [String: Any], embeddedDate: Date?, embeddedApp: String?) {
        let sharedAt = Self.date(inbox[InboxKey.sharedAt])
        self.init(
            app: embeddedApp,
            url: (inbox[InboxKey.url] as? String).flatMap(URL.init(string:)),
            fileName: Self.nonEmpty(inbox[InboxKey.fileName]),
            title: Self.nonEmpty(inbox[InboxKey.title]),
            sharedAt: sharedAt
        )
        if let embeddedDate {
            date = embeddedDate
            dateBasis = .embedded
        } else {
            let candidates = [inbox[InboxKey.fileCreated], inbox[InboxKey.fileModified]]
                .compactMap(Self.date)
                .filter { candidate in
                    guard let sharedAt else { return true }
                    return sharedAt.timeIntervalSince(candidate) > 60
                }
            if let earliest = candidates.min() {
                date = earliest
                dateBasis = .file
            }
        }
    }

    public init?(metadata: [String: Any]) {
        guard let dict = metadata[Self.metadataKey] as? [String: Any] else { return nil }
        self.init(
            app: Self.nonEmpty(dict["app"]),
            url: (dict["url"] as? String).flatMap(URL.init(string:)),
            fileName: Self.nonEmpty(dict["fileName"]),
            title: Self.nonEmpty(dict["title"]),
            date: Self.date(dict["date"]),
            dateBasis: (dict["dateBasis"] as? String).flatMap(DateBasis.init(rawValue:)),
            sharedAt: Self.date(dict["sharedAt"])
        )
    }

    public var isEmpty: Bool {
        app == nil && url == nil && fileName == nil && title == nil && date == nil
    }

    public var metadataValue: [String: Any] {
        var dict: [String: Any] = [:]
        if let app { dict["app"] = app }
        if let url { dict["url"] = url.absoluteString }
        if let fileName { dict["fileName"] = fileName }
        if let title { dict["title"] = title }
        if let date { dict["date"] = ISO8601.string(from: date) }
        if let dateBasis { dict["dateBasis"] = dateBasis.rawValue }
        if let sharedAt { dict["sharedAt"] = ISO8601.string(from: sharedAt) }
        return dict
    }

    /// One line for "where from": the app, the link's site, or the original
    /// file name, joined when there are several ("Safari · example.com").
    public var displayString: String? {
        var parts: [String] = []
        if let app { parts.append(app) }
        if let host = url?.host {
            parts.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        } else if let fileName, app == nil {
            parts.append(fileName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601.parseEither(string)
    }
}
