import Foundation

/// Semantic outcome of a successful transcription run.
///
/// Absence means legacy/unknown metadata. `noSpeech` is deliberately distinct
/// from an empty provider response, which is a transcription failure.
public enum TranscriptionSpeechStatus: String, Codable, Sendable {
    case speech
    case noSpeech = "no_speech"
}

public struct Note: Identifiable, Hashable, Codable, Sendable {
    // MARK: - Immutable identity fields
    public let id: UUID
    public let fileURL: URL
    public let fileCreated: Date
    public let start: Double
    public let end: Double
    public let text: String
    public let hasRaw: Bool
    public let screenshotURL: URL?
    public let metadataURL: URL?
    /// Lowercased in-memory projection of sidecar JSON used by linear search.
    /// Derived while loading a note and intentionally omitted from Codable output.
    public let metadataSearchText: String
    public let documentPageCount: Int?
    /// Human-readable device provenance ("macOS · Michas-MacBook-Pro");
    /// nil for legacy notes written before the origin key existed.
    public let origin: String?
    public let transcriptionProvider: String?
    public let transcriptionModel: String?
    public let transcriptionSpeechStatus: TranscriptionSpeechStatus?
    public let detectedAudioSpeechLabel: AudioSpeechLabel?
    public let audioSpeechLabelOverride: AudioSpeechLabel?
    public var audioSpeechLabel: AudioSpeechLabel? { audioSpeechLabelOverride ?? detectedAudioSpeechLabel }
    /// Unified extraction metadata: OCR, document text, or any other extraction
    public let extractionProvider: String?
    public let extractionModel: String?
    public let attachments: [NoteAttachment]
    public let fileModified: Date
    public let isFailed: Bool
    /// True when the note entered the library through an import flow rather
    /// than being captured by Wimm.
    public let isImported: Bool

    // MARK: - Mutable state (mutated at runtime)
    public var index: Int
    public var refinedText: String?
    public var projectId: String?
    public var projectName: String?
    public var projectConfidence: Double?
    public var projectWhy: String?
    public var title: String?
    public var summary: String?
    public var agentRecommendation: String?
    public var agentReason: String?
    public var isArtifact: Bool
    public var isLiked: Bool
    public var isDraft: Bool
    public var isInsight: Bool
    /// Flagged by the silence audit: the stored transcript was likely fabricated on
    /// silent/no-speech audio. Non-destructive review hint, never auto-deletes.
    public var suspectedNoSpeech: Bool
    public var processedAt: Date?
    public var isCanceled: Bool
    public var connectedNoteIds: [String]?

    public var isUnprocessed: Bool { processedAt == nil }
    public var duration: Double { max(0, end - start) }
    public var absoluteDate: Date { fileCreated.addingTimeInterval(start) }
    public var lastActivityRecordDate: Date { max(fileModified, absoluteDate) }

    /// The text this note hands to the pasteboard: the refined transcript once
    /// analysis has produced one, the raw transcript before that. `nil` when
    /// there is nothing a person would want pasted — the placeholders that
    /// stand in for a missing transcript are status text, not content, and must
    /// never land in the document the user pasted into.
    ///
    /// This is the single rule behind the HUD rows, their copy/paste buttons,
    /// and the ⌥V hotkey; they only agree as long as they all read it here.
    public var insertableText: String? {
        let candidate = (refinedText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isFailed else { return nil }
        let lowered = candidate.lowercased()
        guard !lowered.hasPrefix("transcription failed"),
              lowered != "no text recognized",
              lowered != "no speech detected" else { return nil }
        return candidate
    }
    /// A short, literal preview of the note text for display.
    public func displayTitle(fallback: @autoclosure () -> String, limit: Int = 120) -> String {
        let body = (refinedText ?? text).drop(while: \.isWhitespace)
        let preview = body.prefix(limit + 1)
        let line = preview.prefix(limit).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lowered = line.lowercased()
        guard !line.isEmpty, !lowered.hasPrefix("transcription failed"),
              lowered != "no text recognized", lowered != "no speech detected",
              lowered != "[[no_speech]]" else { return fallback() }
        return preview.count > limit ? line + "…" : line
    }

    enum CodingKeys: String, CodingKey {
        case id, index, fileURL, fileCreated, start, end, text, refinedText, isFailed, isImported
        case screenshotURL, metadataURL, documentPageCount, origin
        case transcriptionProvider, transcriptionModel, transcriptionSpeechStatus, hasRaw
        case detectedAudioSpeechLabel, audioSpeechLabelOverride
        case projectId, projectName, projectConfidence, projectWhy
        case extractionProvider
        case extractionModel
        // Legacy keys (read-only)
        case ocrProvider
        case ocrModel
        case documentTextProvider
        case documentTextModel
        case attachments
        case title, summary, isArtifact, isLiked, isDraft, isInsight, processedAt, isUnprocessed,
            isCanceled, connectedNoteIds, fileModified, suspectedNoSpeech
        case agentRecommendation, agentReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)

        let relFileURL = try container.decode(String.self, forKey: .fileURL)
        fileURL = StoragePaths.resolveRelativePath(relFileURL)

        fileCreated = try container.decode(Date.self, forKey: .fileCreated)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        refinedText = try container.decodeIfPresent(String.self, forKey: .refinedText)
        isFailed = try container.decode(Bool.self, forKey: .isFailed)
        isImported = try container.decodeIfPresent(Bool.self, forKey: .isImported) ?? false

        if let relScreenshotURL = try container.decodeIfPresent(String.self, forKey: .screenshotURL)
        {
            screenshotURL = StoragePaths.resolveRelativePath(relScreenshotURL)
        } else {
            screenshotURL = nil
        }

        if let relMetadataURL = try container.decodeIfPresent(String.self, forKey: .metadataURL) {
            metadataURL = StoragePaths.resolveRelativePath(relMetadataURL)
        } else {
            metadataURL = nil
        }
        metadataSearchText = ""

        documentPageCount = try container.decodeIfPresent(Int.self, forKey: .documentPageCount)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        transcriptionProvider = try container.decodeIfPresent(
            String.self, forKey: .transcriptionProvider)
        transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
        transcriptionSpeechStatus = try container.decodeIfPresent(
            TranscriptionSpeechStatus.self,
            forKey: .transcriptionSpeechStatus
        )
        detectedAudioSpeechLabel = try container.decodeIfPresent(AudioSpeechLabel.self, forKey: .detectedAudioSpeechLabel)
        audioSpeechLabelOverride = try container.decodeIfPresent(AudioSpeechLabel.self, forKey: .audioSpeechLabelOverride)
        hasRaw = try container.decode(Bool.self, forKey: .hasRaw)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        projectConfidence = try container.decodeIfPresent(Double.self, forKey: .projectConfidence)
        projectWhy = try container.decodeIfPresent(String.self, forKey: .projectWhy)

        // Lazy migration:
        // Prefer new keys, but accept legacy ones from older persisted notes.
        extractionProvider = try container.decodeIfPresent(String.self, forKey: .extractionProvider)
            ?? container.decodeIfPresent(String.self, forKey: .ocrProvider)
            ?? container.decodeIfPresent(String.self, forKey: .documentTextProvider)
        extractionModel = try container.decodeIfPresent(String.self, forKey: .extractionModel)
            ?? container.decodeIfPresent(String.self, forKey: .ocrModel)
            ?? container.decodeIfPresent(String.self, forKey: .documentTextModel)

        attachments = try container.decode([NoteAttachment].self, forKey: .attachments)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        agentRecommendation = try container.decodeIfPresent(
            String.self, forKey: .agentRecommendation)
        agentReason = try container.decodeIfPresent(String.self, forKey: .agentReason)
        isArtifact = try container.decode(Bool.self, forKey: .isArtifact)
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        isInsight = try container.decodeIfPresent(Bool.self, forKey: .isInsight) ?? false
        suspectedNoSpeech = try container.decodeIfPresent(Bool.self, forKey: .suspectedNoSpeech) ?? false
        isCanceled = try container.decodeIfPresent(Bool.self, forKey: .isCanceled) ?? false
        connectedNoteIds = try container.decodeIfPresent([String].self, forKey: .connectedNoteIds)
        fileModified = try container.decode(Date.self, forKey: .fileModified)

        // Migration logic:
        if let processed = try container.decodeIfPresent(Date.self, forKey: .processedAt) {
            processedAt = processed
        } else if let unproc = try container.decodeIfPresent(Bool.self, forKey: .isUnprocessed) {
            processedAt = unproc ? nil : Date(timeIntervalSince1970: 0)
        } else {
            processedAt = Date(timeIntervalSince1970: 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(index, forKey: .index)
        try container.encode(StoragePaths.relativePath(for: fileURL), forKey: .fileURL)
        try container.encode(fileCreated, forKey: .fileCreated)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(text, forKey: .text)
        try container.encode(refinedText, forKey: .refinedText)
        try container.encode(isFailed, forKey: .isFailed)
        try container.encode(isImported, forKey: .isImported)

        if let screenshotURL = screenshotURL {
            try container.encode(StoragePaths.relativePath(for: screenshotURL), forKey: .screenshotURL)
        }
        if let metadataURL = metadataURL {
            try container.encode(StoragePaths.relativePath(for: metadataURL), forKey: .metadataURL)
        }

        try container.encode(documentPageCount, forKey: .documentPageCount)
        try container.encode(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encode(transcriptionModel, forKey: .transcriptionModel)
        try container.encodeIfPresent(
            transcriptionSpeechStatus,
            forKey: .transcriptionSpeechStatus
        )
        try container.encode(hasRaw, forKey: .hasRaw)
        try container.encodeIfPresent(detectedAudioSpeechLabel, forKey: .detectedAudioSpeechLabel)
        try container.encodeIfPresent(audioSpeechLabelOverride, forKey: .audioSpeechLabelOverride)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(projectConfidence, forKey: .projectConfidence)
        try container.encode(projectWhy, forKey: .projectWhy)
        // Encode only new keys (legacy keys are not written anymore)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(extractionProvider, forKey: .extractionProvider)
        try container.encodeIfPresent(extractionModel, forKey: .extractionModel)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(agentRecommendation, forKey: .agentRecommendation)
        try container.encode(agentReason, forKey: .agentReason)
        try container.encode(isArtifact, forKey: .isArtifact)
        try container.encode(isLiked, forKey: .isLiked)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encode(isInsight, forKey: .isInsight)
        try container.encode(suspectedNoSpeech, forKey: .suspectedNoSpeech)
        try container.encode(processedAt, forKey: .processedAt)  // Encode new field
        try container.encode(isCanceled, forKey: .isCanceled)
        try container.encode(connectedNoteIds, forKey: .connectedNoteIds)
        try container.encode(fileModified, forKey: .fileModified)
    }

    public init(
        id: UUID,
        index: Int,
        fileURL: URL,
        fileCreated: Date,
        start: Double,
        end: Double,
        text: String,
        refinedText: String? = nil,
        isFailed: Bool,
        isImported: Bool = false,
        screenshotURL: URL? = nil,
        metadataURL: URL? = nil,
        metadataSearchText: String = "",
        documentPageCount: Int? = nil,
        origin: String? = nil,
        transcriptionProvider: String? = nil,
        transcriptionModel: String? = nil,
        transcriptionSpeechStatus: TranscriptionSpeechStatus? = nil,
        detectedAudioSpeechLabel: AudioSpeechLabel? = nil,
        audioSpeechLabelOverride: AudioSpeechLabel? = nil,
        hasRaw: Bool,
        projectId: String? = nil,
        projectName: String? = nil,
        projectConfidence: Double? = nil,
        projectWhy: String? = nil,
        extractionProvider: String? = nil,
        extractionModel: String? = nil,
        attachments: [NoteAttachment] = [],
        title: String? = nil,
        summary: String? = nil,
        agentRecommendation: String? = nil,
        agentReason: String? = nil,
        fileModified: Date = Date(),
        isArtifact: Bool = false,
        isLiked: Bool = false,
        isDraft: Bool = false,
        isInsight: Bool = false,
        suspectedNoSpeech: Bool = false,
        processedAt: Date? = nil,
        isUnprocessed: Bool = false,
        isCanceled: Bool = false,
        connectedNoteIds: [String]? = nil
    ) {
        self.id = id
        self.index = index
        self.fileURL = fileURL
        self.fileCreated = fileCreated
        self.start = start
        self.end = end
        self.text = text
        self.refinedText = refinedText
        self.isFailed = isFailed
        self.isImported = isImported
        self.screenshotURL = screenshotURL
        self.metadataURL = metadataURL
        self.metadataSearchText = metadataSearchText.lowercased()
        self.documentPageCount = documentPageCount
        self.origin = origin
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionModel = transcriptionModel
        self.transcriptionSpeechStatus = transcriptionSpeechStatus
        self.detectedAudioSpeechLabel = detectedAudioSpeechLabel
        self.audioSpeechLabelOverride = audioSpeechLabelOverride
        self.hasRaw = hasRaw
        self.projectId = projectId
        self.projectName = projectName
        self.projectConfidence = projectConfidence
        self.projectWhy = projectWhy
        self.extractionProvider = extractionProvider
        self.extractionModel = extractionModel
        self.attachments = attachments
        self.title = title
        self.summary = summary
        self.agentRecommendation = agentRecommendation
        self.agentReason = agentReason
        self.fileModified = fileModified
        self.isArtifact = isArtifact
        self.isLiked = isLiked
        self.isDraft = isDraft
        self.isInsight = isInsight
        self.suspectedNoSpeech = suspectedNoSpeech

        if let processedAt = processedAt {
            self.processedAt = processedAt
        } else if isUnprocessed {
            self.processedAt = nil
        } else {
            // isUnprocessed is false, meaning it IS processed.
            // But processedAt wasn't provided (nil).
            // We set a default processed date for legacy compatibility.
            // Using fileModified as a proxy for "processed when modified" or distant past.
            self.processedAt = Date(timeIntervalSince1970: 0)
        }

        self.isCanceled = isCanceled
        self.connectedNoteIds = connectedNoteIds
    }

}

public struct AggregateView: Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let summary: String
    public let keyPoints: [String]
    public let keyInfo: [String]
    public let todos: [String]
    public let sourceNoteIds: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        keyPoints: [String],
        keyInfo: [String],
        todos: [String],
        sourceNoteIds: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.keyInfo = keyInfo
        self.todos = todos
        self.sourceNoteIds = sourceNoteIds
        self.createdAt = createdAt
    }
}

public struct FileSegment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public let created: Date
    public let duration: Double
    public let offset: Double

    enum CodingKeys: String, CodingKey {
        case id, url, created, duration, offset
    }

    public init(id: UUID = UUID(), url: URL, created: Date, duration: Double, offset: Double) {
        self.id = id
        self.url = url
        self.created = created
        self.duration = duration
        self.offset = offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let relURL = try container.decode(String.self, forKey: .url)
        url = StoragePaths.resolveRelativePath(relURL)
        created = try container.decode(Date.self, forKey: .created)
        duration = try container.decode(Double.self, forKey: .duration)
        offset = try container.decode(Double.self, forKey: .offset)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(StoragePaths.relativePath(for: url), forKey: .url)
        try container.encode(created, forKey: .created)
        try container.encode(duration, forKey: .duration)
        try container.encode(offset, forKey: .offset)
    }
}
