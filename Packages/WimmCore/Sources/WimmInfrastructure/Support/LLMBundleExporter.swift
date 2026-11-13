import Foundation
import WimmDomain

/// Service to export notes into an LLM-friendly "Chronicle" bundle.
/// Focuses on chronological consistency, compactness, and zero redundancy.
public actor LLMBundleExporter {
    public static let shared = LLMBundleExporter()

    private let metadataRepository = MetadataRepository()
    private lazy var attachmentRepository = AttachmentRepository(
        metadataRepository: metadataRepository)

    public struct ExportOptions {
        /// Include OCR text from images and documents
        public var includeAttachmentsOCR: Bool = true
        /// Skip notes that haven't been processed by LLM yet
        public var filterUnprocessed: Bool = true
        /// Minimum content length to be included (to avoid "noisy" short recordings)
        public var minContentLength: Int = 10

        public init() {}
    }

    public init() {}

    /// Exports notes to a bundle directory.
    /// A bundle is a directory containing a chronicle.md and essential metadata.
    public func exportBundle(
        for noteURLs: [URL], to destination: URL, options: ExportOptions = .init()
    ) async throws -> URL {
        let fm = FileManager.default
        let bundleURL = destination.appendingPathExtension("wimmbundle")

        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // 1. Generate Markdown
        let entries = await getEntries(for: noteURLs, options: options)
        let compacted = compactEntries(entries, options: options)

        let assetsURL = bundleURL.appendingPathComponent("assets")
        try fm.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        let chronicleMD = generateMarkdown(for: compacted, options: options, assetsURL: assetsURL)
        try chronicleMD.write(
            to: bundleURL.appendingPathComponent("chronicle.md"), atomically: true, encoding: .utf8)

        // 2. Generate Manifest
        let manifest: [String: Any] = [
            "version": "1.0",
            "exportedAt": ISO8601.now,
            "noteCount": compacted.count,
            "originalNoteCount": noteURLs.count,
            "options": [
                "filterUnprocessed": options.filterUnprocessed,
                "includeOCR": options.includeAttachmentsOCR,
            ],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: .prettyPrinted)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))

        return bundleURL
    }

    private func getEntries(for noteURLs: [URL], options: ExportOptions) async -> [ChronicleEntry] {
        var entries: [ChronicleEntry] = []
        for url in noteURLs {
            // Load metadata via repository (handles .meta.json)
            let fullMeta = await metadataRepository.metadata(for: url)

            // 1. Determine Timestamp
            // Try standard fields in order of preference
            var timestamp: Date? = nil

            if let tsStr = fullMeta["timestamp"] as? String {  // RecordingMetadata standard
                timestamp = ISO8601.date(from: tsStr)
            }

            if timestamp == nil, let createdStr = fullMeta["createdAt"] as? String {  // WimmMeta standard
                timestamp = ISO8601.date(from: createdStr)
            }

            if timestamp == nil, let trans = fullMeta["transcription"] as? [String: Any],
                let startedStr = trans["startedAt"] as? String
            {
                timestamp = ISO8601.date(from: startedStr)
            }

            // Try filename parsing (Wimm_YYYY-MM-DD...)
            if timestamp == nil {
                timestamp = FileStore.recordingDateFromFileName(url)
            }

            if timestamp == nil {
                // Fallback to file creation
                timestamp =
                    try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]
                    as? Date
            }

            let finalTimestamp = timestamp ?? Date()

            // 2. Load NoteCard
            let card = await metadataRepository.existingNoteCard(for: url)

            if (fullMeta["isCanceled"] as? Bool) == true { continue }

            if options.filterUnprocessed && !(card?.isProcessed ?? false) {
                continue
            }

            // 3. Determine Content
            var content: String? = card?.refined_text

            // Fallback to transcription/document text if refined text is missing
            if content == nil || content?.isEmpty == true {
                if let trans = fullMeta["transcription"] as? [String: Any] {
                    content = trans["transcript"] as? String ?? trans["text"] as? String
                }
            }

            if content == nil || content?.isEmpty == true {
                if let doc = fullMeta["document"] as? [String: Any] {
                    content = doc["text"] as? String
                }
            }

            // If still no content, maybe it's in the RecordingMetadata legacy structure (unlikely if fullMeta logic worked)
            // But let's check top-level "transcription" string if it exists (legacy)
            if content == nil, let legacyTrans = fullMeta["transcription"] as? String {
                content = legacyTrans
            }

            // Fallback: Read raw file content if it is a text file and we have no content yet
            if (content == nil || content?.isEmpty == true)
                && url.pathExtension.lowercased() == "txt"
            {
                content = try? String(contentsOf: url, encoding: .utf8)
            }

            guard let finalContent = content, finalContent.count >= options.minContentLength else {
                continue
            }

            let attachments = await attachmentRepository.attachments(for: url)

            entries.append(
                ChronicleEntry(
                    timestamp: finalTimestamp,
                    id: url.lastPathComponent,
                    title: card?.title ?? "Untitled",
                    summary: card?.summary ?? "",
                    content: finalContent,
                    isArtifact: card?.is_artifact ?? false,
                    isInsight: card?.is_insight ?? false,
                    attachments: attachments
                ))
        }
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    private func getEntries(for notes: [Note], options: ExportOptions) -> [ChronicleEntry] {
        notes.compactMap { note in
            guard !note.isCanceled else { return nil }

            return ChronicleEntry(
                timestamp: note.absoluteDate,
                id: note.id.uuidString,
                title: note.title ?? "Untitled",
                summary: note.summary ?? "",
                content: note.refinedText ?? note.text,
                isArtifact: note.isArtifact,
                isInsight: note.isInsight,
                attachments: note.attachments
            )
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private func generateMarkdown(
        for compacted: [ChronicleEntry], options: ExportOptions, assetsURL: URL? = nil
    ) -> String {
        var md = "# Wimm Stream\n"
        md += "Generated: \(FileStore.fullDateTime(Date()))\n"
        md += "Entries: \(compacted.count)\n\n"
        md += "---\n\n"

        for entry in compacted {
            // Stream Header: Date • Time | Title
            md += "## \(FileStore.fullDateTime(entry.timestamp)) | \(entry.title)\n\n"

            // Meta block (Summary as quote for context separation)
            if !entry.summary.isEmpty {
                md += "> **Summary**: \(entry.summary)\n\n"
            }

            // Main Content (Direct, no label for better flow)
            md += "\(entry.content)\n\n"

            // Context/Attachments block
            if options.includeAttachmentsOCR && !entry.attachments.isEmpty {
                let ocrs = entry.attachments.compactMap { a -> String? in
                    guard let text = a.extractedText, !text.isEmpty else { return nil }
                    let fileName = a.url.lastPathComponent

                    // Try to copy asset if baseURL is provided
                    if let baseURL = assetsURL {
                        let target = baseURL.appendingPathComponent(fileName)
                        if !FileManager.default.fileExists(atPath: target.path) {
                            try? FileManager.default.copyItem(at: a.url, to: target)
                        }
                    }

                    var out = "> **[Attachment: \(fileName)]**\n"
                    out += "> \(text.replacingOccurrences(of: "\n", with: "\n> "))\n"
                    return out
                }
                if !ocrs.isEmpty {
                    md += ocrs.joined(separator: "\n")
                    md += "\n\n"
                }
            }

            md += "---\n\n"
        }
        return md
    }

    /// Generates a single Markdown file content summarizing the notes.
    public func generateMarkdownChronicle(for noteURLs: [URL], options: ExportOptions = .init())
        async -> String
    {
        let entries = await getEntries(for: noteURLs, options: options)
        let compacted = compactEntries(entries, options: options)
        return generateMarkdown(for: compacted, options: options, assetsURL: nil)
    }

    /// Generates Markdown from already-resolved notes without re-reading note metadata from disk.
    public func generateMarkdownChronicle(for notes: [Note], options: ExportOptions = .init()) -> String {
        let entries = getEntries(for: notes, options: options)
        let compacted = compactEntries(entries, options: options)
        return generateMarkdown(for: compacted, options: options, assetsURL: nil)
    }

    private func compactEntries(_ entries: [ChronicleEntry], options: ExportOptions)
        -> [ChronicleEntry]
    {
        // Rot protection / deduplication disabled as requested.
        // We return the entries as-is, just ensuring they are chronologically sorted (which getEntries already does).
        return entries
    }

}

private struct ChronicleEntry {
    let timestamp: Date
    let id: String
    let title: String
    let summary: String
    let content: String
    let isArtifact: Bool
    let isInsight: Bool
    let attachments: [NoteAttachment]
}
