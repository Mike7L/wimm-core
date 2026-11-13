import Foundation
import WimmDomain

#if SWIFTDATA_ENABLED && canImport(SwiftData) && !SPM_TESTS
    import SwiftData
#endif

/// Handles NoteCard read/write and metadata operations.
public actor MetadataRepository: @preconcurrency MetadataRepositoryProtocol {
    public struct TranscriptionInfo: Sendable {
        public let provider: String?
        public let model: String?
        public let hasRaw: Bool
        public let speechStatus: TranscriptionSpeechStatus?

        public init(
            provider: String?,
            model: String?,
            hasRaw: Bool,
            speechStatus: TranscriptionSpeechStatus? = nil
        ) {
            self.provider = provider
            self.model = model
            self.hasRaw = hasRaw
            self.speechStatus = speechStatus
        }
    }

    private let fileManager = FileManager.default

    // MARK: - In-memory metadata cache (avoids re-reading .meta.json within the same batch)
    private struct CachedMeta {
        let rawData: Data
        let dict: [String: Any]
    }
    private var metaCache: [String: CachedMeta] = [:]
    private var metaCacheTimestamp: Date?
    private let metaCacheTTL: TimeInterval = 2.0

    /// Successful physical sidecar reads, including legacy fallbacks. Useful
    /// for verifying that journal updates do not decode unchanged entries.
    public private(set) var sidecarReadCount = 0

    public init() {}

    private func readSidecar(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        sidecarReadCount += 1
        return data
    }

    /// Ensure raw Data + parsed dict are cached for this file. Returns the cache entry.
    @discardableResult
    private func ensureCached(for file: URL) -> CachedMeta? {
        let key = file.lastPathComponent
        // Check TTL: if cache is older than TTL, wipe everything
        if let ts = metaCacheTimestamp, Date().timeIntervalSince(ts) > metaCacheTTL {
            metaCache.removeAll(keepingCapacity: true)
            metaCacheTimestamp = nil
        }
        if let cached = metaCache[key] {
            return cached
        }
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = readSidecar(at: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let entry = CachedMeta(rawData: data, dict: obj)
        metaCache[key] = entry
        if metaCacheTimestamp == nil { metaCacheTimestamp = Date() }
        return entry
    }

    /// Returns parsed dict from cache (convenience for dict-based consumers).
    private func cachedMeta(for file: URL) -> [String: Any] {
        return ensureCached(for: file)?.dict ?? [:]
    }

    /// Returns raw Data from cache (for direct Codable decode without double-parse).
    private func cachedRawData(for file: URL) -> Data? {
        return ensureCached(for: file)?.rawData
    }

    /// Invalidate cache for a specific file (call after writes)
    private func invalidateMetaCache(for file: URL) {
        metaCache.removeValue(forKey: file.lastPathComponent)
    }

    /// Minimal Codable wrapper — decodes only noteCard from raw .meta.json Data in one pass
    private struct MetaNoteCardWrapper: Decodable {
        let noteCard: NoteCard?
    }

    // MARK: - NoteCards

    /// One disk read and one JSON parse. The note card is decoded from its
    /// own object, not by parsing the whole sidecar a second time.
    public func metadataForBuild(
        for file: URL,
        includeSearchText: Bool
    ) -> sending (dictionary: [String: Any], noteCard: NoteCard?, searchText: String) {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = readSidecar(at: metaURL),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([:], nil, "") }
        let card = Self.noteCard(in: dictionary)
        let searchText = includeSearchText
            ? NoteBuilder.searchableMetadataText(bytes: data, parsed: dictionary)
            : ""
        return (dictionary, card, searchText)
    }

    public func metadataAndNoteCard(for file: URL) -> sending ([String: Any], NoteCard?) {
        let built = metadataForBuild(for: file, includeSearchText: false)
        return (built.dictionary, built.noteCard)
    }

    /// Decode only the card object. Journal construction no longer runs a
    /// second parser over transcripts and attachment text.
    static func noteCard(in metadata: [String: Any]) -> NoteCard? {
        guard let object = metadata["noteCard"], !(object is NSNull),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(NoteCard.self, from: data)
    }

    public func existingNoteCard(for file: URL) -> NoteCard? {
        // Direct Codable decode from raw Data — no dict→re-serialize round trip
        guard let data = cachedRawData(for: file) else { return nil }
        do {
            return try JSONDecoder().decode(MetaNoteCardWrapper.self, from: data).noteCard
        } catch {
            log("existingNoteCard: Decoding failed for \(file.lastPathComponent): \(error)")
            return nil
        }
    }

    public func noteCardHasContent(_ card: NoteCard) -> Bool {
        let trimmedTitle = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedTitle.isEmpty || !trimmedSummary.isEmpty
    }

    public func naiveNoteCard(for file: URL, transcript: String) -> NoteCard? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let title =
            trimmed.split(separator: ".").first.map { String($0.prefix(64)) }
            ?? String(trimmed.prefix(64))
        let summary = trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
        return NoteCard(
            note_file: file.lastPathComponent, lang: nil, title: title, summary: summary)
    }

    public func upsertNoteCard(for file: URL, card: NoteCard, lang: String?) {
        NoteMeta.upsertNoteCard(for: file, card: card, lang: lang)
        invalidateMetaCache(for: file)
    }

    #if SWIFTDATA_ENABLED && canImport(SwiftData) && !SPM_TESTS
        /// Update a NoteMetaEntity by noteId using a closure to modify the entity.
        public func updateNoteMetaEntity(noteId: String, update: @escaping @Sendable (NoteMetaEntity) -> Void)
        {
            let context = SwiftDataContextProvider.newContext()
            let nPred = #Predicate<NoteMetaEntity> { $0.id == noteId }
            do {
                if let entity = try context.fetch(FetchDescriptor<NoteMetaEntity>(predicate: nPred))
                    .first
                {
                    update(entity)
                    entity.updatedAt = Date()
                    try context.save()
                }
            } catch {
                log("updateNoteMetaEntity failed for \(noteId): \(error)")
            }
        }
    #endif

    // MARK: - Metadata

    public func metadata(for file: URL) -> sending [String: Any] {
        // Read fresh from disk to satisfy Swift 6 'sending' — result is in a disconnected region
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = readSidecar(at: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// safe update of metadata file
    public func upsertMetadata(for file: URL, updates: [String: Any]) {
        FileStore.upsertMetadata(for: file, updates: updates)
        invalidateMetaCache(for: file)
    }

    public func transcriptionInfo(for file: URL) -> TranscriptionInfo {
        // Try cached dict first (avoids re-reading the file)
        let obj = cachedMeta(for: file)
        if let transcription = obj["transcription"] as? [String: Any] {
            return transcriptionInfoFromDict(transcription, file: file)
        }
        // Fallback to mini file (not cached — rare path)
        let fallbackMini = FileStore.metadataURL(
            forRecordingURL: FileStore.miniURL(forRecordingURL: file))
        if let parsed = parseTranscriptionMeta(at: fallbackMini) {
            return applyInference(parsed: parsed, file: file)
        }
        return TranscriptionInfo(provider: nil, model: nil, hasRaw: false)
    }

    /// Build TranscriptionInfo from a pre-parsed transcription dict (cache-friendly path)
    private func transcriptionInfoFromDict(_ transcription: [String: Any], file: URL) -> TranscriptionInfo {
        let provider = (transcription["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (transcription["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (transcription["raw"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRaw = !(raw ?? "").isEmpty
        let speechStatus = (transcription["speechStatus"] as? String)
            .flatMap(TranscriptionSpeechStatus.init(rawValue:))
        let parsed = (
            info: TranscriptionInfo(
                provider: provider,
                model: model,
                hasRaw: hasRaw,
                speechStatus: speechStatus
            ),
            raw: raw
        )
        return applyInference(parsed: parsed, file: file)
    }

    /// Resolve an already-read dictionary without a second sidecar read or a
    /// migration write. Legacy callers of transcriptionInfo(for:) retain their
    /// mini-sidecar fallback and persistence behavior.
    nonisolated public static func transcriptionInfo(from transcription: [String: Any]) -> TranscriptionInfo {
        func value(_ key: String) -> String? {
            guard let text = (transcription[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        let provider = value("provider")
        let model = value("model")
        let raw = value("raw")
        // Complete metadata needs no parsing of a potentially large raw
        // provider response. Missing raw alone never triggers inference.
        let inferred = provider == nil || model == nil
            ? inferProviderAndModel(existingModel: model, raw: raw)
            : (provider: nil as String?, model: nil as String?)
        return TranscriptionInfo(
            provider: provider ?? inferred.provider,
            model: model ?? inferred.model,
            hasRaw: raw != nil,
            speechStatus: value("speechStatus").flatMap(TranscriptionSpeechStatus.init(rawValue:))
        )
    }

    /// Shared inference + persistence logic for transcription metadata
    private func applyInference(parsed: (info: TranscriptionInfo, raw: String?), file: URL) -> TranscriptionInfo {
        let inferred = Self.inferProviderAndModel(existingModel: parsed.info.model, raw: parsed.raw)
        let provider = parsed.info.provider ?? inferred.provider
        let model = parsed.info.model ?? inferred.model
        if provider != parsed.info.provider || model != parsed.info.model {
            FileStore.mutateTranscription(for: file) { transcription in
                if let provider { transcription["provider"] = provider }
                if let model { transcription["model"] = model }
                return true
            }
            invalidateMetaCache(for: file)
            return TranscriptionInfo(
                provider: provider,
                model: model,
                hasRaw: parsed.info.hasRaw,
                speechStatus: parsed.info.speechStatus
            )
        }
        return TranscriptionInfo(
            provider: parsed.info.provider,
            model: parsed.info.model,
            hasRaw: parsed.info.hasRaw,
            speechStatus: parsed.info.speechStatus
        )
    }

    // MARK: - Private helpers

    private func parseTranscriptionMeta(at url: URL) -> (info: TranscriptionInfo, raw: String?)? {
        guard fileManager.fileExists(atPath: url.path),
            let data = readSidecar(at: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let transcription = json["transcription"] as? [String: Any]
        else {
            return nil
        }
        let provider = (transcription["provider"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let model = (transcription["model"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let raw = (transcription["raw"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRaw = !(raw ?? "").isEmpty
        let speechStatus = (transcription["speechStatus"] as? String)
            .flatMap(TranscriptionSpeechStatus.init(rawValue:))
        return (
            TranscriptionInfo(
                provider: provider,
                model: model,
                hasRaw: hasRaw,
                speechStatus: speechStatus
            ),
            raw
        )
    }

    nonisolated private static func inferProviderAndModel(existingModel: String?, raw: String?) -> (
        provider: String?, model: String?
    ) {
        var provider: String?
        var model = existingModel

        if let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if model == nil,
                let candidate = (dict["model"] as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                !candidate.isEmpty
            {
                model = candidate
            }
            if provider == nil {
                let p = (dict["provider"] as? String) ?? (dict["vendor"] as? String)
                let trimmed = p?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty { provider = trimmed }
            }
        }

        if let raw, !raw.isEmpty {
            if model == nil, let value = capture("\"model\"", in: raw) { model = value }
            if provider == nil, let value = capture("\"provider\"", in: raw) { provider = value }
        }

        if let model, provider == nil {
            let lower = model.lowercased()
            if lower.hasPrefix("gpt-") {
                provider = "openai"
            } else if lower.hasPrefix("gemini-") || lower.hasPrefix("models/") {
                provider = LLMCfg.Provider.gemini.rawValue
            } else if model.contains("/") {
                provider = String(model.split(separator: "/").first ?? "")
            }
        }

        return (provider, model)
    }

    nonisolated private static func capture(_ key: String, in string: String) -> String? {
        let pattern = "\\\(key)\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1
        else { return nil }
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else { return nil }
        return nsString.substring(with: captureRange)
    }
}
