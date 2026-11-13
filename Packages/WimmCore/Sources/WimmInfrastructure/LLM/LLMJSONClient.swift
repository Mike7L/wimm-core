import Foundation
import WimmDomain

// LLM client: JSON-in/JSON-out prompts for NoteCard and batch planning.
public actor LLMJSONClient {
    private let transport: LLMTransport
    private let model: String
    private let capability: ModelCapability
    private let tracer: (@Sendable (String) -> Void)?
    private let transcriptionGlossary: TranscriptionGlossary?
    private let personalGlossaryStore: PersonalGlossaryStore?
    /// nil reads `PrivateMode.isEnabled` once per call.
    private let privateMode: Bool?
    /// Sensitive terms to mask; nil loads them from `personalGlossaryStore`.
    private let pseudonymDictionary: [PseudonymFilter.DictionaryTerm]?
    private let pseudonymMapArchive: PseudonymMapArchive?

    public struct NoteCardResult: Sendable {
        public let card: NoteCard
        /// Set only when the request went out masked.
        public let pseudonymization: PseudonymizationReceipt?
    }

    public init(
        model: String, tracer: (@Sendable (String) -> Void)?, transport: LLMTransport = .shared,
        capability: ModelCapability = .understand,
        transcriptionGlossary: TranscriptionGlossary? = .production,
        personalGlossaryStore: PersonalGlossaryStore? = .shared,
        privateMode: Bool? = nil,
        pseudonymDictionary: [PseudonymFilter.DictionaryTerm]? = nil,
        pseudonymMapArchive: PseudonymMapArchive? = .shared
    ) {
        self.model = model
        self.tracer = tracer
        self.transport = transport
        self.capability = capability
        self.transcriptionGlossary = transcriptionGlossary
        self.personalGlossaryStore = personalGlossaryStore
        self.privateMode = privateMode
        self.pseudonymDictionary = pseudonymDictionary
        self.pseudonymMapArchive = pseudonymMapArchive
    }
    public static func makeDefault() -> LLMJSONClient {
        return LLMJSONClient(
            model: ModelSelection.model(for: .understand), tracer: nil, capability: .understand)
    }

    public init(
        capability: ModelCapability, tracer: (@Sendable (String) -> Void)?,
        transport: LLMTransport = .shared,
        transcriptionGlossary: TranscriptionGlossary? = .production,
        personalGlossaryStore: PersonalGlossaryStore? = .shared
    ) {
        let selectedModel = ModelSelection.model(for: capability)
        self.model = selectedModel
        self.tracer = tracer
        self.transport = transport
        self.capability = capability
        self.transcriptionGlossary = transcriptionGlossary
        self.personalGlossaryStore = personalGlossaryStore
        self.privateMode = nil
        self.pseudonymDictionary = nil
        self.pseudonymMapArchive = .shared
    }

    private func call(
        system: String, userJSON: String, origin: String = #function, reason: String? = nil,
        privacy: Privacy? = nil
    ) async throws -> PerformResult {
        return try await perform(
            system: system, userJSON: userJSON, temperature: 0.2, schema: nil,
            timeout: LLMCfg.requestTimeout, responseMimeType: "application/json",
            traceTag: "LLM response ←", origin: origin, reason: reason, privacy: privacy)
    }

    /// Whether and with which dictionary one call is masked. Resolved once per
    /// call so the glossary that is sent and the masking agree.
    struct Privacy: Sendable {
        let enabled: Bool
        let dictionary: [PseudonymFilter.DictionaryTerm]
    }

    struct PerformResult: Sendable {
        let text: String
        let metadata: [String: String]
        let pseudonymization: PseudonymizationReceipt?
    }

    private func resolvedPrivacy() async throws -> Privacy {
        let enabled = privateMode ?? PrivateMode.isEnabled
        guard enabled else { return Privacy(enabled: false, dictionary: []) }
        if let pseudonymDictionary { return Privacy(enabled: true, dictionary: pseudonymDictionary) }
        let dictionary = try await personalGlossaryStore?
            .analysisVocabulary(bundled: nil, privateMode: true).pseudonymDictionary ?? []
        return Privacy(enabled: true, dictionary: dictionary)
    }

    public func makeNoteCard(
        noteId: String, transcript: String, lang: String?, fileName: String,
        localTranscript: String? = nil,
        origin: String = "LLMJSONClient.makeNoteCard", reason: String? = nil
    ) async -> NoteCard? {
        await makeNoteCardResult(
            noteId: noteId, transcript: transcript, lang: lang, fileName: fileName,
            localTranscript: localTranscript, origin: origin, reason: reason)?.card
    }

    /// `makeNoteCard` plus the pseudonymization receipt for the caller to stamp.
    public func makeNoteCardResult(
        noteId: String, transcript: String, lang: String?, fileName: String,
        localTranscript: String? = nil,
        origin: String = "LLMJSONClient.makeNoteCard", reason: String? = nil
    ) async -> NoteCardResult? {
        let request: NoteCardRequest
        do {
            guard let built = try await noteCardRequest(
                noteId: noteId, transcript: transcript, lang: lang, localTranscript: localTranscript,
                privateMode: privateMode ?? PrivateMode.isEnabled)
            else { return nil }
            request = built
        } catch {
            logAndTrace("Cannot build NoteCard request (vocabulary or encoding): \(error)")
            return nil
        }
        let sys = request.system, user = request.user, privacy = request.privacy
        do {
            let result = try await call(
                system: sys, userJSON: user, origin: origin, reason: reason, privacy: privacy)
            let metadata = result.metadata
            let clean = LLMText.stripFences(result.text)
            // Be tolerant to note_id vs note_file
            if let d = clean.data(using: .utf8),
                let f = try? JSONDecoder().decode(NoteCardExtractionResult.self, from: d)
            {
                let nf = f.note_file ?? f.note_id ?? fileName
                warnIfRefinedTextLooksSummarized(f.refined_text, transcript: transcript)
                let card = NoteCard(
                    schema: f.schema ?? Schemas.noteCard,
                    note_file: nf,
                    lang: f.lang,
                    title: f.title,
                    summary: f.summary,
                    refined_text: f.refined_text,
                    agent_recommendation: f.agent_recommendation,
                    agent_reason: f.agent_reason,
                    provider: metadata["provider"],
                    model_used: metadata["model"]
                )
                return NoteCardResult(card: card, pseudonymization: result.pseudonymization)
            }
        } catch {
            logAndTrace("NoteCard LLM error: \(error)")
        }
        return nil
    }

    struct NoteCardRequest: Sendable {
        let system: String
        let user: String
        let privacy: Privacy
    }

    /// The one place a NoteCard request is assembled: analysis and the private
    /// preview both call it, so the preview cannot drift from what is sent.
    private func noteCardRequest(
        noteId: String, transcript: String, lang: String?, localTranscript: String?, privateMode enabled: Bool,
        archiveVocabulary: Bool = true
    ) async throws -> NoteCardRequest? {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        var sys = PromptLoader.load("transcription_note_card_extraction")
        let transcriptionGlossary: TranscriptionGlossary?
        let privacy: Privacy
        if let personalGlossaryStore {
            let vocabulary = try await personalGlossaryStore.analysisVocabulary(
                bundled: self.transcriptionGlossary, privateMode: enabled, archiveSnapshot: archiveVocabulary)
            transcriptionGlossary = vocabulary.glossary
            privacy = Privacy(enabled: enabled, dictionary: pseudonymDictionary ?? vocabulary.pseudonymDictionary)
        } else {
            transcriptionGlossary = self.transcriptionGlossary
            privacy = Privacy(enabled: enabled, dictionary: pseudonymDictionary ?? [])
        }
        if transcriptionGlossary?.protocolVersion == "context-v4-personal" {
            sys += "\n" + TranscriptionGlossary.personalPromptContract
        }
        if privacy.enabled {
            sys += "\n" + Self.pseudonymPromptContract
        }
        let trimmedLocal = localTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try Self.noteCardInputJSON(
            noteId: noteId,
            transcript: transcript,
            localHypothesis: (trimmedLocal?.isEmpty == false) ? trimmedLocal : nil,
            lang: lang,
            glossary: transcriptionGlossary
        )
        return NoteCardRequest(system: sys, user: user, privacy: privacy)
    }

    /// What a private-mode NoteCard analysis of this text would send, built by
    /// the same request builder and masking code as the real call. Local only:
    /// no model call, no log entry, and the map is not archived.
    public func previewPrivateEgress(
        noteId: String, transcript: String, lang: String?, localTranscript: String? = nil
    ) async throws -> PrivateEgressPreview {
        guard let request = try await noteCardRequest(
            noteId: noteId, transcript: transcript, lang: lang, localTranscript: localTranscript,
            privateMode: true, archiveVocabulary: false)
        else { throw PseudonymizationError.cloudRequestRefused("an empty note") }
        do {
            let inspection = try PseudonymizedPayload.inspect(
                user: request.user, filter: Self.egressFilter(request.privacy))
            return PrivateEgressPreview(
                system: request.system, inspection: inspection,
                dictionaryTerms: request.privacy.dictionary.count, refusal: nil)
        } catch let error as PseudonymizationError {
            return PrivateEgressPreview(
                system: request.system, inspection: nil,
                dictionaryTerms: request.privacy.dictionary.count, refusal: error.localizedDescription)
        }
    }

    static func egressFilter(_ privacy: Privacy) -> PseudonymFilter {
        PseudonymFilter(dictionary: privacy.dictionary)
    }

    static func noteCardInputJSON(
        noteId: String,
        transcript: String,
        localHypothesis: String?,
        lang: String?,
        glossary: TranscriptionGlossary?,
        createdAt: Date = Date()
    ) throws -> String {
        struct NoteInputInfo: Encodable {
            let id: String
            let text: String
            let localHypothesis: String?
            let lang: String?
            let createdAt: String
            let speakers: [String]
            let glossary: TranscriptionGlossary?
        }
        struct ExtractionInput: Encodable {
            let schema: String
            let note: NoteInputInfo
        }

        let input = ExtractionInput(
            schema: Schemas.noteCard,
            note: NoteInputInfo(
                id: noteId,
                text: transcript,
                localHypothesis: localHypothesis,
                lang: lang,
                createdAt: ISO8601.string(from: createdAt),
                speakers: ["S1"],
                glossary: glossary
            )
        )
        let data = try JSONEncoder().encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "LLMJSONClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode NoteCard input as UTF-8"]
            )
        }
        return json
    }

    /// Grooming a transcript removes fillers, so some shrinkage is expected; collapsing it to a
    /// fraction of the original means the model summarized instead of grooming. Diagnostic only —
    /// the card keeps whatever the model returned.
    private func warnIfRefinedTextLooksSummarized(_ refined: String?, transcript: String) {
        guard let refined else { return }
        let refinedLen = refined.trimmingCharacters(in: .whitespacesAndNewlines).count
        let sourceLen = transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard refinedLen > 0, sourceLen > 400 else { return }
        if Double(refinedLen) / Double(sourceLen) < 0.6 {
            logAndTrace(
                "NoteCard refined_text looks summarized (\(refinedLen)/\(sourceLen) chars)")
        }
    }

    // Analyze a group of cards (texts only) and return a Markdown analysis.
    public func analyzeCardsText(texts: [String]) async -> String? {
        struct Input: Encodable { let cards_texts: [String] }
        let sys = PromptLoader.load("project_cards_analysis_markdown")

        guard
            let user = try? String(
                data: JSONEncoder().encode(Input(cards_texts: texts)), encoding: .utf8)
        else { return nil }

        do {
            // Gemini v1beta doesn't allow "text/markdown" responseMimeType. Request as plain text and still prompt for Markdown content.
            let out = try await call(system: sys, userJSON: user, origin: #function).text
            let clean = LLMText.stripFences(out)
            // If the output is wrapped in JSON string quotes by mistake, try to decode or return as is.
            // Usually call() returns the content string.
            let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logAndTrace("Cards analysis LLM error: \(error)")
            return nil
        }
    }

    // Types moved to LLMClientTypes.swift

    // MARK: - Generic Instruction & Insights

    public func performInstruction(instruction: String, context: String) async -> String? {
        let sys = PromptLoader.load("agent_generic_instruction")
        let user = "INSTRUCTION: \(instruction)\n\nCONTEXT:\n\(context)"

        do {
            let out = try await perform(
                system: sys, userJSON: user, temperature: 0.2, schema: nil,
                timeout: LLMCfg.requestTimeout, responseMimeType: "text/plain",
                traceTag: "LLM response (instruction) ←", origin: #function).text
            let clean = LLMText.stripFences(out)
            let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logAndTrace("Perform instruction LLM error: \(error)")
            return nil
        }
    }

    private func logAndTrace(_ message: String) {
        log(message)
        if let tracer {
            Task { @MainActor in tracer(message) }
        }
    }

    private func resolvedOrigin(_ origin: String) -> String {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "LLMJSONClient.unknown" }
        if trimmed.contains(".") {
            return trimmed
        }
        return "LLMJSONClient.\(trimmed)"
    }

    private func requestKind(from parsedJSON: [String: Any]?, fallbackUser: String) -> String {
        if let parsedJSON, let schema = parsedJSON["schema"] as? String {
            switch schema {
            case Schemas.noteCard:
                return "note_card"
            case Schemas.notesAnalysis:
                return "notes_analysis"
            case "CombineCardsInput@v2":
                return "combine_cards"
            case "SeedMergeInput@v1":
                return "seed_merge"
            default:
                return "json"
            }
        }
        if fallbackUser.contains("INSTRUCTION:") && fallbackUser.contains("CONTEXT:") {
            return "instruction"
        }
        return "text"
    }

    private func buildLogAttributes(origin: String, userJSON: String) -> [String: String] {
        var parsedJSON: [String: Any]? = nil
        if let data = userJSON.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            parsedJSON = raw
        }

        var attributes: [String: String] = [
            "requester": "LLMJSONClient",
            "request_kind": requestKind(from: parsedJSON, fallbackUser: userJSON),
            "capability": capability.rawValue,
        ]

        if let parsedJSON, let schema = parsedJSON["schema"] as? String, !schema.isEmpty {
            attributes["schema"] = schema
        }
        if let parsedJSON,
            let note = parsedJSON["note"] as? [String: Any],
            let noteID = note["id"] as? String,
            !noteID.isEmpty
        {
            attributes["note_id"] = noteID
        }
        if let parsedJSON, let cards = parsedJSON["cards"] as? [Any] {
            attributes["cards_count"] = String(cards.count)
        }
        attributes["origin_method"] = origin
        // Cost attribution: which note this call is billed to, and what kind of
        // work it was. `wimm-cli cost` groups by these two.
        let operation = LLMCostContext.operation
            ?? LLMCostContext.inferOperation(
                requestKind: attributes["request_kind"] ?? "text",
                capability: capability)
        attributes["operation"] = operation.rawValue
        if let noteFile = LLMCostContext.noteFile, !noteFile.isEmpty {
            attributes["note_file"] = noteFile
        }
        return attributes
    }

    private func enrichLogAttributesForError(_ attributes: [String: String], error: Error)
        -> [String: String]
    {
        var merged = attributes
        let ns = error as NSError
        if let attempts = ns.userInfo["RetryAttempts"] as? Int {
            merged["attempt"] = String(attempts + 1)
        }
        if let fallbackReason = ns.userInfo["FallbackReason"] as? String, !fallbackReason.isEmpty {
            merged["fallback_reason"] = fallbackReason
        }
        return merged
    }


    /// Unified provider-specific execution with shared tracing and error handling.
    private func perform(
        system: String, userJSON: String, temperature: Double, schema: [String: Any]?,
        timeout: TimeInterval, responseMimeType: String, traceTag: String,
        modelOverride: String? = nil, origin: String = #function, reason: String? = nil,
        privacy: Privacy? = nil
    ) async throws -> PerformResult {
        if let mode = ProcessInfo.processInfo.environment["WIMM_TEST_MODE"] {
            if mode == "FAIL_JSON" {
                return PerformResult(text: "Invalid JSON {", metadata: ["provider": "test", "model": "mock_fail"], pseudonymization: nil)
            }
            // Default success mock
            let mockJson = """
                {
                    "schema": "NoteCard",
                    "note_file": "test_note.txt",
                    "lang": "en",
                    "title": "Mocked Note Title",
                    "summary": "This is a mocked summary for testing.",
                    "refined_text": null,
                    "agent_recommendation": "None",
                    "agent_reason": "Testing"
                }
                """
            return PerformResult(text: mockJson, metadata: ["provider": "test", "model": "mock"], pseudonymization: nil)
        }

        let effModel = modelOverride ?? model
        let provider = ModelProviderFactory.create(
            capability: capability, identifier: effModel, transport: transport)
        let logOrigin = resolvedOrigin(origin)
        // Attribution is read from the real payload: masking may rewrite note ids.
        var logAttributes = buildLogAttributes(origin: logOrigin, userJSON: userJSON)

        // Single egress point. Everything below — the queue preview, the
        // tracer, the event log and the provider — sees only the masked copy.
        let effectivePrivacy: Privacy
        if let privacy { effectivePrivacy = privacy } else { effectivePrivacy = try await resolvedPrivacy() }
        var pseudonymized: PseudonymizedPayload?
        var pseudonymization: PseudonymizationReceipt?
        let isCloud = provider.provider == .gemini || provider.provider == .openrouter
        if effectivePrivacy.enabled && isCloud {
            let payload = try PseudonymizedPayload.mask(user: userJSON, filter: Self.egressFilter(effectivePrivacy))
            let mapSha256 = try pseudonymMapArchive?.archive(payload.map) ?? payload.map.sha256()
            pseudonymized = payload
            pseudonymization = PseudonymizationReceipt(mapSha256: mapSha256, counts: payload.map.counts)
            logAttributes["private_mode"] = "1"
            logAttributes["pseudonym_map_sha256"] = mapSha256
            logAttributes["pseudonym_entities"] = String(payload.map.entries.count)
        }
        let sentUser = pseudonymized?.user ?? userJSON
        if let reason = reason, !reason.isEmpty {
            logAttributes["reason"] = reason
        }
        let queueType = Self.queueType(for: capability)
        let requestKind = logAttributes["request_kind"] ?? "json"
        let manualQueueJobId: UUID? = if !LLMQueueContext.inUnifiedQueue {
            await MainActor.run {
                UnifiedModelManager.shared.beginManualJob(
                    type: queueType,
                    input: String(sentUser.prefix(160)),
                    priority: .normal,
                    engine: effModel,
                    context: [
                        "origin": logOrigin,
                        "request_kind": requestKind,
                    ]
                )
            }
        } else {
            nil
        }

        let cid = LLMLogger.shared.logRequest(
            model: effModel,
            provider: provider.provider.rawValue,
            origin: logOrigin,
            attributes: logAttributes,
            system: system,
            user: sentUser,
            isStreaming: false
        )

        if let tracer {
            await MainActor.run {
                tracer(
                    "LLM request → provider=\(provider.provider.rawValue) model=\(effModel)\nSYSTEM:\n\(system)\n\nUSER:\n\(sentUser)"
                )
            }
        }

        do {
            let request = ModelRequest(
                system: system,
                user: sentUser,
                temperature: temperature,
                schema: schema,
                timeout: timeout,
                responseMimeType: responseMimeType,
                traceTag: traceTag
            )
            let response = try await PrivateMode.withPseudonymizedEgress {
                try await provider.performDetailed(request: request, tracer: tracer)
            }
            let result = response.text
            var responseAttributes = logAttributes
            if let usage = response.usage, !usage.isEmpty {
                responseAttributes.merge(usage.logAttributes) { _, new in new }
            }
            LLMLogger.shared.logResponse(
                model: effModel,
                provider: provider.provider.rawValue,
                origin: logOrigin,
                attributes: responseAttributes,
                system: system,
                user: sentUser,
                response: result,
                isStreaming: false,
                correlationId: cid
            )
            if let manualQueueJobId {
                await MainActor.run {
                    UnifiedModelManager.shared.completeManualJob(
                        jobId: manualQueueJobId,
                        output: String(result.prefix(160))
                    )
                }
            }
            let restored = try pseudonymized?.unmask(response: result) ?? result
            return PerformResult(text: restored, metadata: provider.metadata, pseudonymization: pseudonymization)
        } catch {
            let errorAttributes = enrichLogAttributesForError(logAttributes, error: error)
            LLMLogger.shared.logResponse(
                model: effModel,
                provider: provider.provider.rawValue,
                origin: logOrigin,
                attributes: errorAttributes,
                system: system,
                user: sentUser,
                response: nil,
                error: error.localizedDescription,
                isStreaming: false,
                correlationId: cid
            )
            if let manualQueueJobId {
                await MainActor.run {
                    UnifiedModelManager.shared.completeManualJob(
                        jobId: manualQueueJobId,
                        error: error.localizedDescription
                    )
                }
            }
            throw error
        }
    }

    static let pseudonymPromptContract = """
    Private mode: personal data in the input is replaced by placeholders such as ⟦P3⟧ (person), ⟦O1⟧ (organisation), ⟦L2⟧ (place), ⟦X1⟧ (other name), ⟦E1⟧ (email), ⟦T1⟧ (phone), ⟦I1⟧ (IBAN), ⟦C1⟧ (card), ⟦A1⟧ (address). Copy every placeholder exactly as written, including any suffix such as ⟦P3:f1⟧. Never invent, renumber, merge, translate or explain placeholders, and never guess what they stand for. In Russian output you may mark the grammatical case of a person, organisation or place placeholder by appending :nom, :gen, :dat, :acc, :ins or :prep, e.g. ⟦P3:dat⟧; use no other suffixes.
    """

    private static func queueType(for capability: ModelCapability) -> ModelType {
        switch capability {
        case .think:
            return .processing
        case .understand:
            return .analysis
        case .hear:
            return .transcription
        case .see:
            return .vision
        }
    }
}
