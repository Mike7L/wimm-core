import Foundation
import AVFoundation
import WimmDomain
import WimmInfrastructure

// Transcription service (network + retry + key rotation)
// Keeps Gemini-specific response parsing localized.

public enum TranscriptionFailureReason: Sendable { case network, decoding, empty, cancelled, tooLarge, rateLimited, badStatus, permissionDenied, notSupported, temporaryUnavailable, privateMode, unknown }
public enum TranscriptionResult: Sendable { case success(String); case failure(TranscriptionFailureReason, underlying: Error?) }

public struct TranscriptionService: Sendable {
    public let rotator: APIKeyRotator
    private let modelProvider: @Sendable () -> String
    public let transport: LLMTransport
    private let orRotator: OpenRouterKeyRotator = .shared
    // private let session: URLSession // Removed to use shared session

    public init(rotator: APIKeyRotator, model: @autoclosure @Sendable @escaping () -> String, transport: LLMTransport) {
        self.rotator = rotator
        self.modelProvider = model
        self.transport = transport
        // self.session = URLSession(configuration: .default) // Removed
    }

    // Container for decoded text and raw response body (when available)
    private struct RawText { let text: String; let raw: String? }

    private func currentModel() -> String {
        modelProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedModel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func geminiFallbackModel() -> String {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["GEMINI_TRANSCRIBE_MODEL"],
            env["GEMINI_MODEL"],
            ModelSelection.defaultGeminiModel
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ModelSelection.defaultGeminiModel
    }

    private func cloudRoute(engine: EngineID, configuredModel: String) -> (provider: LLMCfg.Provider, model: String) {
        switch engine {
        case .openrouter:
            return (.openrouter, configuredModel)
        case .gemini:
            let provider = ModelRouter.provider(for: configuredModel)
            if provider == .gemini {
                return (.gemini, configuredModel)
            }
            return (.gemini, geminiFallbackModel())
        case .native:
            let provider = ModelRouter.provider(for: configuredModel)
            if provider == .openrouter || provider == .gemini {
                return (provider, configuredModel)
            }
            return (.gemini, geminiFallbackModel())
        }
    }

    private func requestTimeout(durationSeconds: Double?) -> TimeInterval {
        let base = LLMCfg.requestTimeout
        guard let duration = durationSeconds, duration.isFinite, duration > 0 else {
            return max(base, 120)
        }
        let dynamic = duration * 2.0 + 60.0
        // Always allow at least 120s and respect the configured request timeout.
        return max(base, dynamic, 120)
    }

// ProgressCoordinator moved to TranscriptionDelegates.swift

// UploadProgressDelegate moved to TranscriptionDelegates.swift

    // OpenRouter request/response
    // Chat Completions payload
    private struct ORMessage: Encodable { let role: String; let content: AnyEncodable }
    private struct ORChatReq: Encodable {
        let model: String
        let messages: [ORMessage]
        let temperature: Double?
        let extra_headers: [String: String]?
    }
    // Responses API payload (supports input_audio across models)
    private struct ORInputMsg: Encodable { let role: String; let content: AnyEncodable }
    private struct ORResponsesReq: Encodable {
        let model: String
        let input: [ORInputMsg]
        let instructions: String?
        let temperature: Double?
        let extra_headers: [String: String]?
    }
    // Flexible decoding to tolerate either string content or array-of-parts content
    private struct ORRespString: Decodable { struct Choice: Decodable { struct Msg: Decodable { let role: String; let content: String? }; let message: Msg }; let choices: [Choice] }
    private struct ORRespParts: Decodable {
        struct Part: Decodable { let type: String?; let text: String? }
        struct Choice: Decodable { struct Msg: Decodable { let role: String; let content: [Part]? }; let message: Msg }
        let choices: [Choice]
    }
    private func decodeORText(_ data: Data) -> String? {
        if let s = try? JSONDecoder().decode(ORRespString.self, from: data) {
            if let t = s.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        if let p = try? JSONDecoder().decode(ORRespParts.self, from: data) {
            let joined = p.choices.first?.message.content?.compactMap { $0.text }.joined(separator: " ") ?? ""
            let t = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    // Decode OpenRouter /responses output (delegated to WimmCore helper for unit testing)
    private func decodeORResponsesText(_ data: Data) -> String? {
        OpenRouterResponseDecoder.decodeResponsesText(data)
    }

    private func networkCallOpenRouter(model: String, key: String, fileURL: URL, durationSeconds: Double?, language: String = "Auto", progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?) async throws -> RawText {
        if Task.isCancelled { throw CancellationError() }
        let audioData = try Data(contentsOf: fileURL)
        let b64 = audioData.base64EncodedString()
        // Optional experimental path: try multipart upload to /audio/transcriptions first
        // Enable with OPENROUTER_USE_TRANSCRIPTIONS=1 (or "true")
        let env = ProcessInfo.processInfo.environment
        let useUpload = ["1","true","yes"].contains(env["OPENROUTER_USE_TRANSCRIPTIONS"]?.lowercased())
        if useUpload {
            do {
                let s = try await networkCallOpenRouterUpload(model: model, key: key, fileURL: fileURL, data: audioData, durationSeconds: durationSeconds)
                return RawText(text: s, raw: nil)
            } catch {
                logDebug("[TranscriptionService] OpenRouter upload fallback error: \(error)")
                // If server rejects (404/400) or other error, fall back to /responses JSON path below
            }
        }
        // Prefer /responses for audio support across models
        let timeout = requestTimeout(durationSeconds: durationSeconds)
        var req = try await transport.makeOpenRouterRequest(path: "responses", timeout: timeout, apiKey: key)
        // Determine audio format for input_audio
        let ext = fileURL.pathExtension.lowercased()
        let fmt: String
    switch ext {
    case "m4a": fmt = "m4a"
    case "mp4": fmt = "mp4"
    case "aac": fmt = "aac"
    case "wav": fmt = "wav"
    case "mp3": fmt = "mp3"
    case "caf": fmt = "wav" // convert caf to wav for safety
    default: fmt = "wav"
    }
        // OpenAI/OpenRouter expects multimodal content parts:
        // { "type": "input_text", "text": "..." }, { "type": "input_audio", "input_audio": { "data": "<b64>", "format": "wav" } }
        let langHint = language == "Auto" ? "" : " The audio is in \(language)."
        let userParts: [[String: Any]] = [
            ["type": "input_text", "text": PromptLoader.load("transcription_standard_prompt", variables: ["lang_hint": langHint])],
            ["type": "input_audio", "input_audio": ["data": b64, "format": fmt]]
        ]
        let systemPrompt = PromptLoader.load("transcription_system_prompt")
        // Prepare Responses API body (preferred)
        let attribution = transport.openRouterAttributionHeaders()
        let bodyR = ORResponsesReq(
            model: model,
            input: [ .init(role: "user", content: AnyEncodable(userParts)) ],
            instructions: systemPrompt,
            temperature: ModelSampling.temperature(0.0, model: model),
            extra_headers: attribution.isEmpty ? nil : attribution
        )
        req.httpBody = try JSONEncoder().encode(bodyR)

        // Simple progress ticker similar to Gemini path
        let t0 = Date()
        let totalEstimate = max(5.0, (durationSeconds ?? 0) * 0.9 + 4.0)
        progress?(0.02, totalEstimate, Date().timeIntervalSince(t0))
    var (data, resp) = try await URLSession.shared.dataSafe(for: req)
        if Task.isCancelled { throw CancellationError() }
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200..<300).contains(http.statusCode) {
            // If /responses not supported for model, or input_audio unsupported, fall back to chat/completions
            let bodyRaw = String(data: data, encoding: .utf8) ?? "<no body>"
            // Fallback to chat/completions only on 400/404
            if http.statusCode == 400 || http.statusCode == 404 {
                // Switch endpoint to chat/completions
                var chatReq = try await transport.makeOpenRouterRequest(path: "chat/completions", timeout: req.timeoutInterval, apiKey: key)
                let bodyChatA = ORChatReq(
                    model: model,
                    messages: [
                        .init(role: "system", content: AnyEncodable(["type": "text", "text": systemPrompt])),
                        .init(role: "user", content: AnyEncodable(userParts))
                    ],
                    temperature: ModelSampling.temperature(0.0, model: model),
                    extra_headers: attribution.isEmpty ? nil : attribution
                )
                let bodyChatB = ORChatReq(
                    model: model,
                    messages: [
                        .init(role: "system", content: AnyEncodable(["type": "text", "text": systemPrompt])),
                        .init(role: "user", content: AnyEncodable(PromptLoader.load("transcription_fallback_prompt"))),
                        .init(role: "user", content: AnyEncodable([["type": "input_audio", "input_audio": ["data": b64, "format": fmt]]]))
                    ],
                    temperature: ModelSampling.temperature(0.0, model: model),
                    extra_headers: attribution.isEmpty ? nil : attribution
                )
                chatReq.httpBody = try JSONEncoder().encode(bodyChatA)
                (data, resp) = try await URLSession.shared.dataSafe(for: chatReq)
                if let http2 = resp as? HTTPURLResponse, !(200..<300).contains(http2.statusCode) {
                    if http2.statusCode == 400 {
                        chatReq.httpBody = try JSONEncoder().encode(bodyChatB)
                        (data, resp) = try await URLSession.shared.dataSafe(for: chatReq)
                    }
                }
                if let http3 = resp as? HTTPURLResponse, !(200..<300).contains(http3.statusCode) {
                    let body2 = String(data: data, encoding: .utf8) ?? "<no body>"
                    throw NSError(domain: ErrorDomain.badStatus, code: http3.statusCode, userInfo: [NSLocalizedDescriptionKey: body2])
                }
                // decode chat response
                let textChat = decodeORText(data) ?? ""
                let trimmedChat = textChat.trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsed = Date().timeIntervalSince(t0)
                progress?(1.0, 0, elapsed)
                if trimmedChat.isEmpty { throw NSError(domain: ErrorDomain.noText, code: 0) }
                return RawText(text: trimmedChat, raw: String(data: data, encoding: .utf8))
            } else {
                throw NSError(domain: ErrorDomain.badStatus, code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyRaw])
            }
        }
        // decode /responses output
        let text = decodeORResponsesText(data) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Date().timeIntervalSince(t0)
        progress?(1.0, 0, elapsed)
        if trimmed.isEmpty {
            // Try a best-effort chat/completions fallback even on 200 when content was empty
            do {
                var chatReq = try await transport.makeOpenRouterRequest(path: "chat/completions", timeout: req.timeoutInterval, apiKey: key)
                let bodyChatA = ORChatReq(
                    model: model,
                    messages: [
                        .init(role: "system", content: AnyEncodable(["type": "text", "text": systemPrompt])),
                        .init(role: "user", content: AnyEncodable(userParts))
                    ],
                    temperature: ModelSampling.temperature(0.0, model: model),
                    extra_headers: attribution.isEmpty ? nil : attribution
                )
                let bodyChatB = ORChatReq(
                    model: model,
                    messages: [
                        .init(role: "system", content: AnyEncodable(["type": "text", "text": systemPrompt])),
                        .init(role: "user", content: AnyEncodable("Please transcribe the following audio.")),
                        .init(role: "user", content: AnyEncodable([["type": "input_audio", "input_audio": ["data": b64, "format": fmt]]]))
                    ],
                    temperature: ModelSampling.temperature(0.0, model: model),
                    extra_headers: attribution.isEmpty ? nil : attribution
                )
                chatReq.httpBody = try JSONEncoder().encode(bodyChatA)
                var (d2, r2) = try await URLSession.shared.dataSafe(for: chatReq)
                if let http2 = r2 as? HTTPURLResponse, !(200..<300).contains(http2.statusCode) || (decodeORText(d2)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    chatReq.httpBody = try JSONEncoder().encode(bodyChatB)
                    (d2, r2) = try await URLSession.shared.dataSafe(for: chatReq)
                }
                if let http3 = r2 as? HTTPURLResponse, (200..<300).contains(http3.statusCode) {
                    if let tChat = decodeORText(d2)?.trimmingCharacters(in: .whitespacesAndNewlines), !tChat.isEmpty {
                        return RawText(text: tChat, raw: String(data: d2, encoding: .utf8))
                    }
                }
            } catch {
                // Ignore and proceed to error mapping below
            }
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let snippet = raw.count > 240 ? String(raw.prefix(237)) + "…" : raw
            log("[OpenRouter] empty transcription response: \(snippet)")
            // Many OpenRouter routes for gpt-4o family (including chatgpt-4o-latest, gpt-4o-mini) don't support input_audio consistently.
            // Map to notSupported to trigger Gemini fallback automatically.
            let m = model.lowercased()
            if m.contains("gpt-4o-mini") || m.contains("chatgpt-4o") || m.contains("gpt-4o-latest") || m == "openai/gpt-4o" {
                throw NSError(domain: ErrorDomain.badStatus, code: 415, userInfo: [NSLocalizedDescriptionKey: "Model does not support input_audio on OpenRouter"])
            } else {
                throw NSError(domain: ErrorDomain.noText, code: 0)
            }
        }
    return RawText(text: trimmed, raw: String(data: data, encoding: .utf8))
    }

    // Multipart upload to OpenRouter /audio/transcriptions (Whisper-compatible). Returns transcript text.
    private func networkCallOpenRouterUpload(model: String, key: String, fileURL: URL, data: Data, durationSeconds: Double?) async throws -> String {
        if Task.isCancelled { throw CancellationError() }
        let boundary = "----wimm-" + UUID().uuidString
        var req = try await transport.makeOpenRouterRequest(
            path: "audio/transcriptions",
            timeout: requestTimeout(durationSeconds: durationSeconds),
            contentType: "multipart/form-data; boundary=\(boundary)",
            apiKey: key
        )

        // Fields
        var fields: [(name: String, value: String)] = []
        fields.append(("model", model))
        // Prefer plain text response; if server ignores, we'll parse JSON
        fields.append(("response_format", "text"))

        // File part
        let filename = fileURL.lastPathComponent.isEmpty ? "audio.m4a" : fileURL.lastPathComponent
        let mime = TranscriptionSupport.guessMime(for: fileURL.pathExtension.lowercased())
        let body = try TranscriptionSupport.buildMultipartBody(
            boundary: boundary,
            fields: fields,
            fileParam: "file",
            filename: filename,
            mimeType: mime,
            fileData: data
        )
        req.httpBody = body
        let (respData, resp) = try await URLSession.shared.dataSafe(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: respData, encoding: .utf8) ?? "<non-utf8 body>"
            throw NSError(domain: ErrorDomain.badStatus, code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try TranscriptionSupport.decodeWhisperResponseText(from: respData)
    }

    private func whisperModelIdentifier(from model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("whisper:") {
            let value = String(trimmed.dropFirst("whisper:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if lower.hasPrefix("whisper/") {
            let value = String(trimmed.dropFirst("whisper/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func classifyTranscriptionError(_ error: Error) -> TranscriptionFailureReason {
        let base = TranscriptionSupport.classify(error)
        if base != .unknown { return base }

        let ns = error as NSError
        let message = ((ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ns.localizedDescription).lowercased()

        switch ns.domain {
        case "GeminiTranscriptionAdapter":
            if ns.code == 401 || ns.code == 403 { return .permissionDenied }
            if ns.code == 413 { return .tooLarge }
            if ns.code == 415 { return .notSupported }
            if ns.code == 429 { return .rateLimited }
            if (500...599).contains(ns.code) { return .temporaryUnavailable }
        case "NativeSpeechAdapter":
            if ns.code == 1004 || ns.code == 1005 { return .permissionDenied }
            if ns.code == 1000 { return .notSupported }
            if ns.code == 1006 { return .temporaryUnavailable }
        case "WhisperKitTranscriptionAdapter":
            if ns.code == 2 || ns.code == 3 { return .notSupported }
            if ns.code == 4 { return .empty }
        default:
            break
        }

        if message.contains("permission") || message.contains("denied") {
            return .permissionDenied
        }
        if message.contains("unsupported") || message.contains("not supported") || message.contains("unavailable") {
            return .notSupported
        }
        if message.contains("rate") || message.contains("quota") {
            return .rateLimited
        }
        if message.contains("too large") || message.contains("exceeds") {
            return .tooLarge
        }
        if message.contains("empty") {
            return .empty
        }

        return .unknown
    }

    private func shouldRotateForTranscriptionError(_ reason: TranscriptionFailureReason, error: Error) -> Bool {
        if TranscriptionSupport.shouldRotate(after: error, reason: reason) { return true }
        switch reason {
        case .permissionDenied, .rateLimited, .temporaryUnavailable, .badStatus:
            return true
        default:
            return false
        }
    }

    private func toCore(_ r: TranscriptionFailureReason) -> CoreTranscriptionFailureReason {
        switch r {
        case .network: return .network
        case .decoding: return .decoding
        case .empty: return .empty
        case .cancelled: return .cancelled
        case .tooLarge: return .tooLarge
        case .rateLimited: return .rateLimited
        case .badStatus: return .badStatus
        case .permissionDenied: return .permissionDenied
        case .notSupported: return .notSupported
        case .temporaryUnavailable: return .temporaryUnavailable
        case .privateMode: return .privateMode
        case .unknown: return .unknown
        }
    }

    /// Preferred API: choose route by configured model/provider.
    public func transcribe(
        file: URL,
        language: String = "Auto",
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)? = nil,
        onPartial: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> TranscriptionResult {
        let model = currentModel()
        let provider = ModelRouter.provider(for: model)
        let engine: EngineID = (provider == .openrouter) ? .openrouter : .gemini
        return await transcribe(
            file: file,
            engine: engine,
            model: model,
            language: language,
            progress: progress,
            onPartial: onPartial
        )
    }

    /// Engine selection injected by the caller (the UI's transcriber engine). We read it lazily to avoid tight coupling.
    public func transcribe(
        file: URL,
        engine: EngineID,
        language: String = "Auto",
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)? = nil,
        onPartial: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> TranscriptionResult {
        await transcribe(
            file: file,
            engine: engine,
            model: currentModel(),
            language: language,
            progress: progress,
            onPartial: onPartial
        )
    }

    public func transcribe(
        file: URL,
        engine: EngineID,
        model configuredModel: String,
        language: String = "Auto",
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)? = nil,
        onPartial: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> TranscriptionResult {
        _ = onPartial
        let model = normalizedModel(configuredModel)
        // Basic existence check before either the deterministic test adapter or
        // the production paths attempt to persist a result.
        if !FileManager.default.fileExists(atPath: file.path) {
            log("Skip transcription – file not found \(file.path)")
            return .failure(.unknown, underlying: NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSLocalizedDescriptionKey: "File not found"]))
        }
        if ProcessInfo.processInfo.environment["WIMM_TEST_MODE"] != nil {
            // The deterministic adapter obeys the same contract as every real
            // success path: TranscriptionService owns the single sidecar write.
            let started = Date()
            let text = "This is a mocked transcription for testing purposes."
            let duration = (try? await AVURLAsset(url: file).load(.duration))
                .map(CMTimeGetSeconds)
            progress?(0.1, 1.0, 0.1)
            progress?(1.0, 1.0, 1.0)
            recordRunSuccess(
                file: file,
                provider: "test",
                model: model,
                audioDuration: duration,
                startedAt: started,
                elapsedSeconds: Date().timeIntervalSince(started),
                transcript: text,
                speechStatus: .speech,
                rawResponse: nil
            )
            return .success(text)
        }
        
        if Task.isCancelled { return .failure(.cancelled, underlying: nil) }
        
        // Keep original for metadata persistence; engines that take a reduced file get a
        // throwaway temp copy (downsampled, silence-trimmed when the map finds gaps),
        // built only on the paths that use it and deleted when this run ends. Nothing
        // persistent is written next to the original; the original is the fallback.
        let originalFile = file
        var uploadFile = file
        var uploadCopy: URL?
        var uploadPrepared = false
        defer { if let uploadCopy { try? FileManager.default.removeItem(at: uploadCopy) } }
        func prepareUpload() {
            guard !uploadPrepared else { return }
            uploadPrepared = true
            if let copy = MicroAudio.makeUploadCopy(original: originalFile) {
                uploadCopy = copy
                uploadFile = copy
            }
        }
        // Use original duration for metadata/UI
        let durationSeconds: Double? = (try? await AVURLAsset(url: originalFile).load(.duration)).map { CMTimeGetSeconds($0) }
        if let whisperModel = whisperModelIdentifier(from: model) {
            let started = Date()
            let totalEstimate = max(5.0, (durationSeconds ?? 0) * 0.9 + 4.0)
            progress?(0.02, totalEstimate, 0)
            do {
                prepareUpload()
                let whisper = WhisperKitTranscriptionAdapter(modelIdentifier: whisperModel)
                let text = try await whisper.transcribeFile(at: uploadFile)
                progress?(1.0, 0, Date().timeIntervalSince(started))
                let parsed = TranscriptionSupport.splitAgentRecommendation(from: text)
                recordRunSuccess(
                    file: originalFile,
                    provider: "whisperkit",
                    model: whisperModel,
                    audioDuration: durationSeconds,
                    startedAt: started,
                    elapsedSeconds: Date().timeIntervalSince(started),
                    transcript: parsed.text,
                    speechStatus: TranscriptionSupport.isNoSpeechSentinel(text)
                        ? .noSpeech : .speech,
                    rawResponse: nil,
                    agentRecommendation: parsed.agent,
                    agentReason: parsed.reason
                )
                return .success(parsed.text)
            } catch {
                return .failure(classifyTranscriptionError(error), underlying: error)
            }
        }
        // On-device Parakeet. Runs before the private-mode refusal on purpose: no audio
        // leaves the machine. An empty result means the model heard no speech — record
        // that as noSpeech instead of a failure, so silence does not get retried.
        // It reads the ORIGINAL, not the micro: the micro only exists to shrink uploads,
        // and its spliced-together pauses make Parakeet invent text on a near-silent note
        // (Wimm_2026-08-16_00-49-12_560B19E3: original → nothing, micro → "1900, 8, 8, 8").
        if ParakeetModel.isParakeet(model) {
            let started = Date()
            let totalEstimate = max(3.0, (durationSeconds ?? 0) * 0.02 + 2.0)
            progress?(0.02, totalEstimate, 0)
            do {
                let parakeet = ParakeetTranscriptionAdapter(modelIdentifier: model, language: language)
                let result = try await parakeet.transcribe(at: originalFile)
                progress?(1.0, 0, Date().timeIntervalSince(started))
                // A low-confidence, nearly wordless result is noSpeech: the note is not
                // analyzed as if it were real, and recordRunSuccess never lets it replace
                // text the note already has. What Parakeet "heard" stays in `raw` for review.
                recordRunSuccess(
                    file: originalFile,
                    provider: "parakeet",
                    model: ParakeetModel.variant(from: model) ?? model,
                    audioDuration: durationSeconds,
                    startedAt: started,
                    elapsedSeconds: Date().timeIntervalSince(started),
                    transcript: result.text,
                    speechStatus: result.looksLikeSilence ? .noSpeech : .speech,
                    rawResponse: result.looksLikeSilence
                        ? String(format: "confidence=%.3f words=%d: %@", result.confidence, result.words, result.text)
                        : nil,
                    confidence: result.confidence,
                    timedWords: result.timedWords
                )
                if !result.looksLikeSilence {
                    // Detached: the note already has its text, and the split (a second model,
                    // tens of seconds on a first load) must not hold the job or its analysis.
                    // On iOS it holds background time, so a split already computing is written
                    // rather than frozen with the app.
                    Task.detached(priority: .utility) {
                        await SpeakerTurnsBackfill.withBackgroundTime("Wimm speaker split") {
                            await Self.recordSpeakerTurns(for: originalFile, transcript: result)
                        }
                    }
                }
                return .success(result.looksLikeSilence ? "" : result.text)
            } catch is CancellationError {
                // iOS ends a backgrounded job this way (seen during the first-run model download);
                // .cancelled lets the queue requeue it instead of marking the note failed.
                return .failure(.cancelled, underlying: nil)
            } catch {
                log("[Parakeet] failed file=\(file.lastPathComponent) error=\(error.localizedDescription)")
                return .failure(classifyTranscriptionError(error), underlying: error)
            }
        }
        // Every path below sends a reduced copy (native speech, cloud upload).
        prepareUpload()
        // Attempt native path if selected; on any failure fall back to Gemini transparently (except cancellation / notSupported / permission issues which are surfaced).
        if engine == .native {
            let tStartNative = Date()
            do {
                let native = NativeSpeechAdapter()
                let text = try await native.transcribeFile(at: uploadFile)
                let parsed = TranscriptionSupport.splitAgentRecommendation(from: text)
                logDebug("transcribe engine=native outcome=success file=\(file.lastPathComponent)")
                recordRunSuccess(
                    file: originalFile,
                    provider: "native",
                    model: "native",
                    audioDuration: durationSeconds,
                    startedAt: tStartNative,
                    elapsedSeconds: Date().timeIntervalSince(tStartNative),
                    transcript: parsed.text,
                    speechStatus: TranscriptionSupport.isNoSpeechSentinel(text)
                        ? .noSpeech : .speech,
                    rawResponse: nil,
                    agentRecommendation: parsed.agent,
                    agentReason: parsed.reason
                )
                return .success(parsed.text)
            } catch {
                let reason = classifyTranscriptionError(error)
                let underlying: Error? = error
                if reason == .permissionDenied || reason == .notSupported {
                    return .failure(reason, underlying: underlying)
                }
                log("[NativeSpeech] fallback reason=\(failureReasonLabel(toCore(reason), underlying: underlying)) file=\(file.lastPathComponent)")
                // continue with cloud engines below
            }
        }



        // Private mode: audio cannot be pseudonymized, so it never goes to a
        // cloud engine. Say so explicitly instead of a generic failure.
        if PrivateMode.isEnabled {
            log("transcribe refused: private mode is on, cloud engine \(engine.rawValue) file=\(file.lastPathComponent)")
            return .failure(.privateMode, underlying: PseudonymizationError.cloudRequestRefused("audio"))
        }
        let route = cloudRoute(engine: engine, configuredModel: model)
        let effProvider = route.provider
        let cloudModel = route.model
        // Gemini transparently switches to the Files API above this threshold.
        // OpenRouter's JSON input_audio route still requires an inline payload.
        if effProvider == .openrouter,
           let size = (try? FileManager.default.attributesOfItem(atPath: uploadFile.path)[.size] as? NSNumber)?.int64Value,
           size > TranscriptionCfg.inlineDataMaxBytes {
            log("Skip OpenRouter transcription – inline audio too large \(size) > \(TranscriptionCfg.inlineDataMaxBytes)")
            return .failure(.tooLarge, underlying: nil)
        }
        logDebug("transcribe engine=cloud(\(effProvider.rawValue)) model=\(cloudModel) requested_engine=\(engine.rawValue) configured_model=\(model) file=\(file.lastPathComponent)")
        // Try with all available keys for the chosen provider, rotating on relevant failures.
        let providerKeys = (effProvider == .gemini) ? await rotator.allKeys() : await orRotator.allKeys()
        let maxKeys = providerKeys.count
        if maxKeys == 0 {
            let message = (effProvider == .gemini) ? "No Gemini API key configured" : "No OpenRouter API key configured"
            let error = NSError(domain: ErrorDomain.badStatus, code: 401, userInfo: [NSLocalizedDescriptionKey: message])
            return .failure(.permissionDenied, underlying: error)
        }
        var lastError: Error? = nil
        var triedGemFallback = false
        for attempt in 0..<maxKeys {
            if Task.isCancelled { return .failure(.cancelled, underlying: lastError) }
            let started = Date()
            let key = providerKeys[attempt]
            do {
                let out: RawText
                if effProvider == .gemini {
                    let totalEstimate = max(5.0, (durationSeconds ?? 0) * 0.9 + 4.0)
                    progress?(0.02, totalEstimate, 0)
                    let adapter = GeminiTranscriptionAdapter(apiKey: key, modelName: cloudModel)
                    let text = try await adapter.transcribeFile(at: uploadFile)
                    progress?(1.0, 0, Date().timeIntervalSince(started))
                    out = RawText(text: text, raw: nil)
                } else {
                    out = try await networkCallOpenRouter(model: cloudModel, key: key, fileURL: uploadFile, durationSeconds: durationSeconds, language: language, progress: progress)
                }
                logDebug(String(format: "transcribe attempt%u ok %.2fs", attempt + 1, Date().timeIntervalSince(started)))
                let parsed = TranscriptionSupport.splitAgentRecommendation(from: out.text)
                // Persist success metadata
                recordRunSuccess(
                    file: originalFile,
                    provider: effProvider.rawValue,
                    model: cloudModel,
                    audioDuration: durationSeconds,
                    startedAt: started,
                    elapsedSeconds: Date().timeIntervalSince(started),
                    transcript: parsed.text,
                    speechStatus: TranscriptionSupport.isNoSpeechSentinel(out.text)
                        ? .noSpeech : .speech,
                    rawResponse: out.raw,
                    agentRecommendation: parsed.agent,
                    agentReason: parsed.reason
                )
                return .success(parsed.text)
            } catch {
                lastError = error
                if Task.isCancelled { return .failure(.cancelled, underlying: error) }
                if effProvider == .gemini {
                    let message = ((error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription).lowercased()
                    if message.contains("api key not valid") {
                        await rotator.quarantine(key)
                    }
                }
                // Handle backoff for 429 when specified.
                if let ns = error as NSError?, ns.domain == ErrorDomain.badStatus, ns.code == 429, let ra = ns.userInfo["GRetryAfter"] as? Int, ra > 0 {
                    let delay = min(ra, 8)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                }
                // Rotate only for key/auth/rate/server issues; keep same key for network flukes to avoid burning keys.
                let reason = classifyTranscriptionError(error)
                // If OpenRouter reports notSupported, try a one-shot Gemini fallback here
                if effProvider == .openrouter && reason == .notSupported && !triedGemFallback {
                    triedGemFallback = true
                    // Choose Gemini model: env overrides or default
                    let env = ProcessInfo.processInfo.environment
                    let gemEnv = (env["GEMINI_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (env["GEMINI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    let gemModel = gemEnv ?? ModelSelection.defaultGeminiModel
                    let gemKeys = await rotator.allKeys()
                    if !gemKeys.isEmpty {
                        let gemStarted = Date()
                        let gKey1 = gemKeys[0]
                        do {
                            let adapter = GeminiTranscriptionAdapter(apiKey: gKey1, modelName: gemModel)
                            let text = try await adapter.transcribeFile(at: uploadFile)
                            let out = RawText(text: text, raw: nil)
                            let parsed = TranscriptionSupport.splitAgentRecommendation(from: out.text)
                            recordRunSuccess(
                                file: originalFile,
                                provider: LLMCfg.Provider.gemini.rawValue,
                                model: gemModel,
                                audioDuration: durationSeconds,
                                startedAt: gemStarted,
                                elapsedSeconds: Date().timeIntervalSince(gemStarted),
                                transcript: parsed.text,
                                speechStatus: TranscriptionSupport.isNoSpeechSentinel(out.text)
                                    ? .noSpeech : .speech,
                                rawResponse: out.raw,
                                agentRecommendation: parsed.agent,
                                agentReason: parsed.reason
                            )
                            return .success(parsed.text)
                        } catch {
                            if gemKeys.count > 1 {
                                let gKey2 = gemKeys[1]
                                if let text2 = try? await GeminiTranscriptionAdapter(apiKey: gKey2, modelName: gemModel).transcribeFile(at: uploadFile) {
                                    let out = RawText(text: text2, raw: nil)
                                    let parsed = TranscriptionSupport.splitAgentRecommendation(from: out.text)
                                    recordRunSuccess(
                                        file: originalFile,
                                        provider: LLMCfg.Provider.gemini.rawValue,
                                        model: gemModel,
                                        audioDuration: durationSeconds,
                                        startedAt: gemStarted,
                                        elapsedSeconds: Date().timeIntervalSince(gemStarted),
                                        transcript: parsed.text,
                                        speechStatus: TranscriptionSupport.isNoSpeechSentinel(out.text)
                                            ? .noSpeech : .speech,
                                        rawResponse: out.raw,
                                        agentRecommendation: parsed.agent,
                                        agentReason: parsed.reason
                                    )
                                    return .success(parsed.text)
                                }
                            }
                            // fallthrough to regular rotation logic
                        }
                    }
                }
                let shouldRotate = shouldRotateForTranscriptionError(reason, error: error)
                logDebug(String(format: "attempt%u fail %.2fs rotate=%@ %@", attempt + 1, Date().timeIntervalSince(started), shouldRotate ? "yes" : "no", String(describing: error)))
                // If not rotating, still provide a brief jitter before retrying same key next loop (which will immediately end if no rotation and maxKeys==1)
                if !shouldRotate { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
        }
        if let error = lastError {
            return .failure(classifyTranscriptionError(error), underlying: error)
        }
        return .failure(.unknown, underlying: nil)
    }


    /// Splits a Parakeet transcript by speaker with the on-device diarizer and stores it beside
    /// the transcript. Never fails the transcription: a missing split costs nothing, a failed
    /// note would be retried. Runs after the job has returned, so the split is written only while
    /// the transcript it was made for is still the current one — a newer run clears it. A split
    /// that never lands (process killed, diarizer failed) is caught up by `SpeakerTurnsBackfill`.
    static func recordSpeakerTurns(for file: URL, transcript: ParakeetTranscript) async {
        guard transcript.audioSeconds >= LocalSpeakerDiarizer.minimumAudioSeconds,
              !transcript.timedWords.isEmpty else { return }
        let started = Date()
        do {
            let record = try await LocalSpeakerDiarizer.record(for: file, words: transcript.timedWords)
            let took = Date().timeIntervalSince(started)
            let stored = SpeakerTurnsBackfill.store(record, for: file, ifTranscriptIs: transcript.text)
            log(String(format: "[Diarization] %@ speakers=%d audio=%.1fs took=%.1fs%@",
                       file.lastPathComponent, record.speakers, transcript.audioSeconds, took,
                       stored ? "" : " skipped=transcript-changed"))
        } catch {
            SpeakerTurnsBackfill.markFailedAttempt(file, transcript: transcript.text, error: error)
            log(String(format: "[Diarization] failed %@ after %.1fs error=%@",
                       file.lastPathComponent, Date().timeIntervalSince(started),
                       error.localizedDescription))
        }
    }
}
