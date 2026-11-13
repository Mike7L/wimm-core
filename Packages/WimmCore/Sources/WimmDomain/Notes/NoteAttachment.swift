import Foundation

// MARK: - Schemas

public enum Schemas {
    public static let noteCard = "NoteCard@v1"
    public static let meta = "WimmMeta@v1"
    public static let notesAnalysis = "NotesAnalysis@v1"
}

// MARK: - AttachmentType

public enum AttachmentType: String, Codable, CaseIterable, Sendable {
    case image = "image"
    case audio = "audio"
    case video = "video"
    case document = "document"
    case pdf = "pdf"
    case other = "other"

    public init(fromMIME mime: String) {
        let lower = mime.lowercased()
        if lower.hasPrefix("image/") {
            self = .image
        } else if lower.hasPrefix("video/") {
            self = .video
        } else if lower.hasPrefix("audio/") {
            self = .audio
        } else if lower.contains("pdf") {
            self = .pdf
        } else if lower.contains("document") || lower.contains("word") || lower.contains("text") {
            self = .document
        } else {
            self = .other
        }
    }

    public init(fromExtension ext: String) {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if ["image", "png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff"].contains(normalized) {
            self = .image
        } else if ["audio", "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac"].contains(
            normalized)
        {
            self = .audio
        } else if ["opus", "oga", "ogg"].contains(normalized) {
            self = .audio
        } else if ["video", "mp4", "mov", "avi", "mkv"].contains(normalized) {
            self = .video
        } else if normalized == "pdf" {
            self = .pdf
        } else if ["doc", "docx", "txt", "md", "markdown", "rtf", "pages"].contains(normalized) {
            self = .document
        } else {
            self = .other
        }
    }
}

// MARK: - NoteAttachment

public struct NoteAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public let type: String  // Raw string for backward compatibility
    /// Unified extracted text: OCR, transcription, or plain-text content
    public let extractedText: String?
    public let extractionProvider: String?
    public let extractionModel: String?

    public var typeEnum: AttachmentType {
        // `type` may store either a canonical AttachmentType raw value ("audio")
        // or a file extension ("opus").
        AttachmentType(rawValue: type) ?? AttachmentType(fromExtension: type)
    }

    public init(
        id: UUID = UUID(), url: URL, type: String, extractedText: String? = nil,
        extractionProvider: String? = nil, extractionModel: String? = nil
    ) {
        self.id = id
        self.url = url
        self.type = type
        self.extractedText = extractedText
        self.extractionProvider = extractionProvider
        self.extractionModel = extractionModel
    }

    public init(
        id: UUID = UUID(), url: URL, type: AttachmentType, extractedText: String? = nil,
        extractionProvider: String? = nil, extractionModel: String? = nil
    ) {
        self.id = id
        self.url = url
        self.type = type.rawValue
        self.extractedText = extractedText
        self.extractionProvider = extractionProvider
        self.extractionModel = extractionModel
    }

    // Lazy migration:
    // - Decode both new keys (extractedText/extractionProvider/extractionModel)
    //   and legacy keys (ocrText/ocrProvider/ocrModel).
    // - Encode only new keys.
    enum CodingKeys: String, CodingKey {
        case id, url, type
        case extractedText
        case extractionProvider
        case extractionModel
        // Legacy keys (read-only)
        case ocrText
        case ocrProvider
        case ocrModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let relURL = try container.decode(String.self, forKey: .url)
                url = StoragePaths.resolveRelativePath(relURL)
        type = try container.decode(String.self, forKey: .type)

        extractedText = try container.decodeIfPresent(String.self, forKey: .extractedText)
            ?? container.decodeIfPresent(String.self, forKey: .ocrText)
        extractionProvider = try container.decodeIfPresent(String.self, forKey: .extractionProvider)
            ?? container.decodeIfPresent(String.self, forKey: .ocrProvider)
        extractionModel = try container.decodeIfPresent(String.self, forKey: .extractionModel)
            ?? container.decodeIfPresent(String.self, forKey: .ocrModel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
                try container.encode(StoragePaths.relativePath(for: url), forKey: .url)
        try container.encode(type, forKey: .type)
        // Encode only new keys (legacy keys are not written anymore)
        try container.encodeIfPresent(extractedText, forKey: .extractedText)
        try container.encodeIfPresent(extractionProvider, forKey: .extractionProvider)
        try container.encodeIfPresent(extractionModel, forKey: .extractionModel)
    }
}

// MARK: - NoteCard

public struct NoteCard: Codable, Sendable {
    public var schema: String = Schemas.noteCard
    public var note_file: String
    public var lang: String?
    public var title: String
    public var summary: String

    public var provider: String? = nil
    public var model_used: String? = nil

    public var refined_text: String?
    /// Set when the user manually edited refined_text. Reprocessing pipelines
    /// must preserve the edited text instead of regenerating it.
    public var refined_edited_at: Date? = nil
    public var agent_recommendation: String? = nil
    public var agent_reason: String? = nil

    public var is_artifact: Bool = false
    public var is_liked: Bool = false
    public var is_insight: Bool = false
    public var is_draft: Bool = false
    public private(set) var processed_at: Date? = nil
    public var connected_note_ids: [String]? = nil

    /// Whether this NoteCard was fully processed by LLM (not a naive fallback stub).
    public var isProcessed: Bool { processed_at != nil }

    /// Reset processing state so the note will be re-processed on next pass.
    public mutating func markForReprocessing() {
        processed_at = nil
    }

    /// Mark as successfully processed (called by NoteProcessor after LLM success).
    public mutating func markProcessed() {
        processed_at = Date()
    }

    /// Carry over everything the user owns from a previous card.
    ///
    /// A regenerated card comes back from the LLM with flags at their defaults
    /// and no knowledge of manual edits, so reprocessing would otherwise wipe
    /// likes, insight/draft marks and hand-edited text. Title, summary and the
    /// agent fields are intentionally left to the fresh card.
    public mutating func preserveUserState(from previous: NoteCard) {
        if previous.refined_edited_at != nil {
            refined_text = previous.refined_text
            refined_edited_at = previous.refined_edited_at
        }
        is_liked = previous.is_liked
        is_insight = previous.is_insight
        is_draft = previous.is_draft
        is_artifact = previous.is_artifact
        connected_note_ids = previous.connected_note_ids ?? connected_note_ids
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case note_file
        case lang
        case title
        case summary
        case refined_text
        case refined_edited_at
        case agent_recommendation
        case agent_reason
        case is_artifact
        case is_liked
        case is_insight
        case is_draft
        case processed_at
        case is_unprocessed  // Legacy
        case connected_note_ids
    }

    public init(
        schema: String = Schemas.noteCard, note_file: String, lang: String?, title: String,
        summary: String, refined_text: String? = nil, refined_edited_at: Date? = nil,
        agent_recommendation: String? = nil,
        agent_reason: String? = nil, is_artifact: Bool = false, is_liked: Bool = false,
        is_insight: Bool = false, is_draft: Bool = false, processed_at: Date? = nil,
        connected_note_ids: [String]? = nil, provider: String? = nil, model_used: String? = nil
    ) {
        self.schema = schema
        self.note_file = note_file
        self.lang = lang
        self.title = title
        self.summary = summary
        self.refined_text = refined_text
        self.refined_edited_at = refined_edited_at
        self.agent_recommendation = agent_recommendation
        self.agent_reason = agent_reason
        self.is_artifact = is_artifact
        self.is_liked = is_liked
        self.is_insight = is_insight
        self.is_draft = is_draft
        self.processed_at = processed_at
        self.connected_note_ids = connected_note_ids
        self.provider = provider
        self.model_used = model_used
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required fields must be present
        schema = try container.decode(String.self, forKey: .schema)
        note_file = try container.decode(String.self, forKey: .note_file)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)

        // Optionals
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        refined_text = try container.decodeIfPresent(String.self, forKey: .refined_text)
        refined_edited_at = try container.decodeIfPresent(Date.self, forKey: .refined_edited_at)
        agent_recommendation = try container.decodeIfPresent(
            String.self, forKey: .agent_recommendation)
        agent_reason = try container.decodeIfPresent(String.self, forKey: .agent_reason)
        connected_note_ids = try container.decodeIfPresent(
            [String].self, forKey: .connected_note_ids)

        // Fields with defaults
        is_artifact = try container.decodeIfPresent(Bool.self, forKey: .is_artifact) ?? false
        is_liked = try container.decodeIfPresent(Bool.self, forKey: .is_liked) ?? false
        is_insight = try container.decodeIfPresent(Bool.self, forKey: .is_insight) ?? false
        is_draft = try container.decodeIfPresent(Bool.self, forKey: .is_draft) ?? false

        // Migration logic:
        if container.contains(.processed_at) {
            // Key exists: decode Date or nil (explicit null = unprocessed)
            processed_at = try container.decodeIfPresent(Date.self, forKey: .processed_at)
        } else if let unproc = try container.decodeIfPresent(Bool.self, forKey: .is_unprocessed) {
            // Legacy field: if true -> unprocessed (nil). If false -> processed (use fallback date)
            processed_at = unproc ? nil : Date(timeIntervalSince1970: 0)
        } else {
            // If neither exists, assume processed (legacy default was is_unprocessed=false)
            processed_at = Date(timeIntervalSince1970: 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(note_file, forKey: .note_file)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(lang, forKey: .lang)
        try container.encodeIfPresent(refined_text, forKey: .refined_text)
        try container.encodeIfPresent(refined_edited_at, forKey: .refined_edited_at)
        try container.encodeIfPresent(agent_recommendation, forKey: .agent_recommendation)
        try container.encodeIfPresent(agent_reason, forKey: .agent_reason)
        try container.encode(is_artifact, forKey: .is_artifact)
        try container.encode(is_liked, forKey: .is_liked)
        try container.encode(is_insight, forKey: .is_insight)
        try container.encode(is_draft, forKey: .is_draft)
        try container.encodeIfPresent(processed_at, forKey: .processed_at)
        try container.encodeIfPresent(connected_note_ids, forKey: .connected_note_ids)
        // We do NOT encode is_unprocessed (legacy field removed from output)
    }
}
