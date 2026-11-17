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

    public struct NoteCardResult: Sendable {
        public let card: NoteCard
    }

    public init(
        model: String, tracer: (@Sendable (String) -> Void)?, transport: LLMTransport = .shared,
        capability: ModelCapability = .understand,
        transcriptionGlossary: TranscriptionGlossary? = .production,
        personalGlossaryStore: PersonalGlossaryStore? = .shared
    ) {
        self.model = model
        self.tracer = tracer
        self.transport = transport
        self.capability = capability
        self.transcriptionGlossary = transcriptionGlossary
        self.personalGlossaryStore = personalGlossaryStore
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
    }

    private func call(
        system: String, userJSON: String, origin: String = #function, reason: String? = nil
    ) async throws -> PerformResult {
        return try await perform(
            system: system, userJSON: userJSON, temperature: 0.2, schema: nil,
            timeout: LLMCfg.requestTimeout, responseMimeType: "application/json",
            traceTag: "LLM response ←", origin: origin, reason: reason)
    }

    struct PerformResult: Sendable {
        let text: String
        let metadata: [String: String]
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

    /// `makeNoteCard` as a result value.
    public func makeNoteCardResult(
        noteId: String, transcript: String, lang: String?, fileName: String,
        localTranscript: String? = nil,
        origin: String = "LLMJSONClient.makeNoteCard", reason: String? = nil
    ) async -> NoteCardResult? {
        let request: NoteCardRequest
        do {
            guard let built = try await noteCardRequest(
                noteId: noteId, transcript: transcript, lang: lang, localTranscript: localTranscript)
            else { return nil }
            request = built
        } catch {
            logAndTrace("Cannot build NoteCard request (vocabulary or encoding): \(error)")
            return nil
        }
        let sys = request.system, user = request.user
        do {
            let result = try await call(
                system: sys, userJSON: user, origin: origin, reason: reason)
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
                return NoteCardResult(card: card)
            }
        } catch {
            logAndTrace("NoteCard LLM error: \(error)")
        }
        return nil
    }

    struct NoteCardRequest: Sendable {
        let system: String
        let user: String
    }

    /// The one place a NoteCard request is assembled.
    private func noteCardRequest(
        noteId: String, transcript: String, lang: String?, localTranscript: String?
    ) async throws -> NoteCardRequest? {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        var sys = PromptLoader.load("transcription_note_card_extraction")
        let transcriptionGlossary: TranscriptionGlossary?
        if let personalGlossaryStore {
            transcriptionGlossary = try await personalGlossaryStore.analysisGlossary(bundled: self.transcriptionGlossary)
        } else {
            transcriptionGlossary = self.transcriptionGlossary
        }
        if transcriptionGlossary?.protocolVersion == "context-v4-personal" {
            sys += "\n" + TranscriptionGlossary.personalPromptContract
        }
        let trimmedLocal = localTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try Self.noteCardInputJSON(
            noteId: noteId,
            transcript: transcript,
            localHypothesis: (trimmedLocal?.isEmpty == false) ? trimmedLocal : nil,
            lang: lang,
            glossary: transcriptionGlossary
        )
        return NoteCardRequest(system: sys, user: user)
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

    // MARK: - Logging

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
        modelOverride: String? = nil, origin: String = #function, reason: String? = nil
    ) async throws -> PerformResult {
        if let mode = ProcessInfo.processInfo.environment["WIMM_TEST_MODE"] {
            if mode == "FAIL_JSON" {
                return PerformResult(text: "Invalid JSON {", metadata: ["provider": "test", "model": "mock_fail"])
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
            return PerformResult(text: mockJson, metadata: ["provider": "test", "model": "mock"])
        }

        let effModel = modelOverride ?? model
        let provider = ModelProviderFactory.create(
            capability: capability, identifier: effModel, transport: transport)
        let logOrigin = resolvedOrigin(origin)
        var logAttributes = buildLogAttributes(origin: logOrigin, userJSON: userJSON)

        let sentUser = userJSON
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
            let response = try await provider.performDetailed(request: request, tracer: tracer)
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
            return PerformResult(text: result, metadata: provider.metadata)
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
