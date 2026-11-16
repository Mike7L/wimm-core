import Foundation

public enum ModelSelection {
    public static let defaultGeminiModel = "gemini-3.5-flash"

    /// Default for streamed conversations: fast enough to answer by voice.
    public static let defaultConversationModel = "gemini-3.8-flash"

    /// True for an id `GeminiChatStream` can call directly.
    public static func isGeminiModel(_ modelId: String) -> Bool {
        trimModelPrefix(modelId.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased().hasPrefix("gemini-")
    }

    /// The model behind Studio's streamed conversations (Алёна, «Ангел и Демон»).
    /// They speak Gemini only, so a stored id of another provider is ignored here
    /// and refused by ``setConversationModel(_:)`` rather than swapped silently.
    public static var conversationModel: String {
        for store in [SharedUserDefaults.store, UserDefaults.standard] {
            if let saved = store.string(forKey: DefaultsKey.conversationModel), isGeminiModel(saved) {
                return trimModelPrefix(saved.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return defaultConversationModel
    }

    /// Stores the conversation model; false (and nothing stored) for a non-Gemini id.
    @discardableResult
    public static func setConversationModel(_ modelId: String) -> Bool {
        guard isGeminiModel(modelId) else { return false }
        let trimmed = trimModelPrefix(modelId.trimmingCharacters(in: .whitespacesAndNewlines))
        SharedUserDefaults.store.set(trimmed, forKey: DefaultsKey.conversationModel)
        UserDefaults.standard.set(trimmed, forKey: DefaultsKey.conversationModel)
        return true
    }

    public static func model(for capability: ModelCapability) -> String {
        // If user explicitly selected "apple/on-device", honor that selection
        // (checked inside resolve via UserDefaults).
        switch capability {
        case .think:
            return resolve(
                primaryKey: DefaultsKey.capabilityThinkModel,
                legacyKey: DefaultsKey.smartModel,
                envKeys: ["GEMINI_SMART_MODEL"],
                defaultModel: defaultGeminiModel
            )
        case .understand:
            return resolve(
                primaryKey: DefaultsKey.capabilityUnderstandModel,
                legacyKey: DefaultsKey.analysisModel,
                envKeys: ["OPENROUTER_MODEL", "GEMINI_MODEL"],
                defaultModel: defaultGeminiModel
            )
        case .hear:
            return resolveTranscribe()
        case .see:
            return resolveVision()
        }
    }

    public static func setModel(_ modelId: String, for capability: ModelCapability) {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let shared = SharedUserDefaults.store
        switch capability {
        case .think:
            shared.set(trimmed, forKey: DefaultsKey.capabilityThinkModel)
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.capabilityThinkModel)
        case .understand:
            shared.set(trimmed, forKey: DefaultsKey.capabilityUnderstandModel)
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.capabilityUnderstandModel)
        case .hear:
            shared.set(trimmed, forKey: DefaultsKey.capabilityHearModel)
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.capabilityHearModel)
        case .see:
            shared.set(trimmed, forKey: DefaultsKey.capabilitySeeModel)
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.capabilitySeeModel)
        }
    }

    private static func resolve(
        primaryKey: String,
        legacyKey: String,
        envKeys: [String],
        defaultModel: String
    ) -> String {
        let shared = SharedUserDefaults.store
        if let saved = shared.string(forKey: primaryKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return trimModelPrefix(saved)
        }
        if let legacy = shared.string(forKey: legacyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            return trimModelPrefix(legacy)
        }
        if let saved = UserDefaults.standard.string(forKey: primaryKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            shared.set(saved, forKey: primaryKey)
            return trimModelPrefix(saved)
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            shared.set(legacy, forKey: legacyKey)
            return trimModelPrefix(legacy)
        }
        let env = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let val = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return trimModelPrefix(val)
            }
        }
        return trimModelPrefix(defaultModel)
    }

    private static func resolveTranscribe() -> String {
        let shared = SharedUserDefaults.store
        if let saved = shared.string(forKey: DefaultsKey.capabilityHearModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return trimModelPrefix(saved)
        }
        if let s = shared.string(forKey: DefaultsKey.transcribeModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return trimModelPrefix(s)
        }
        if let saved = UserDefaults.standard.string(forKey: DefaultsKey.capabilityHearModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            shared.set(saved, forKey: DefaultsKey.capabilityHearModel)
            return trimModelPrefix(saved)
        }
        if let s = UserDefaults.standard.string(forKey: DefaultsKey.transcribeModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            shared.set(s, forKey: DefaultsKey.transcribeModel)
            return trimModelPrefix(s)
        }
        let env = ProcessInfo.processInfo.environment
        let gemT = env["GEMINI_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let orT  = env["OPENROUTER_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let gem  = env["GEMINI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let or   = env["OPENROUTER_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen: String = {
            if let orT, !orT.isEmpty { return orT }
            if let gemT, !gemT.isEmpty { return gemT }
            if let or, !or.isEmpty { return or }
            if let gem, !gem.isEmpty { return gem }
            return defaultGeminiModel
        }()
        return trimModelPrefix(chosen)
    }

    private static func resolveVision() -> String {
        let shared = SharedUserDefaults.store
        if let saved = shared.string(forKey: DefaultsKey.capabilitySeeModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return trimModelPrefix(saved)
        }
        if let saved = UserDefaults.standard.string(forKey: DefaultsKey.capabilitySeeModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            shared.set(saved, forKey: DefaultsKey.capabilitySeeModel)
            return trimModelPrefix(saved)
        }
        // Use current OCR engine selection
        let engine = Config.documentOcrEngine
        switch engine {
        case .mlx:
            return LocalPhotoModel.identifier
        case .vision:
            return "vision"
        case .gemini:
            return trimModelPrefix(Config.documentOcrGeminiModel)
        case .miniCPM:
            return trimModelPrefix(Config.documentOcrOpenRouterModel)
        }
    }

    private static func trimModelPrefix(_ value: String) -> String {
        if value.hasPrefix("models/") {
            return String(value.dropFirst("models/".count))
        }
        return value
    }
}
