import Foundation

public enum Config {
    // Unified model picker for JSON LLM tasks (aka analysis: note cards, induction).
    // Order of precedence: UserDefaults.analysisModel -> env (provider-specific) -> sensible default.
    // Computed each access so changes in Settings apply immediately.
    public static var model: String {
        ModelSelection.model(for: .understand)
    }
    
    // Model for "Smart" capabilities (reasoning, deep thinking)
    public static var smartModel: String {
        ModelSelection.model(for: .think)
    }

    /// Transcription model (provider-aware).
    /// - If provider is Gemini: UserDefaults -> GEMINI_TRANSCRIBE_MODEL/GEMINI_MODEL -> default gemini-3.5-flash.
    /// - If provider is OpenRouter: UserDefaults -> OPENROUTER_TRANSCRIBE_MODEL/OPENROUTER_MODEL -> default openai/gpt-4o-mini.
    /// Computed each access so changes in Settings apply immediately.
    public static var transcribeModel: String {
        ModelSelection.model(for: .hear)
    }

    public static var seeModel: String {
        ModelSelection.model(for: .see)
    }

    public static func model(for capability: ModelCapability) -> String {
        ModelSelection.model(for: capability)
    }

    public static func isLocalModel(_ identifier: String) -> Bool {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("local/")
    }
    
    public static func localModelName(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("local/") {
            return String(trimmed.dropFirst("local/".count))
        }
        return trimmed
    }

    public static var documentOcrEngine: DocumentOCREngine {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.documentOCREngine),
           let engine = DocumentOCREngine(rawValue: raw) {
            return engine
        }
        if let raw = ProcessInfo.processInfo.environment["WIMM_DOC_OCR_ENGINE"],
           let engine = DocumentOCREngine(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return engine
        }
        return .vision
    }

    public static var documentOcrGeminiModel: String {
        if let saved = UserDefaults.standard.string(forKey: DefaultsKey.documentOCRGeminiModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved.hasPrefix("models/") ? String(saved.dropFirst("models/".count)) : saved
        }
        if let env = ProcessInfo.processInfo.environment["GEMINI_DOC_OCR_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env.hasPrefix("models/") ? String(env.dropFirst("models/".count)) : env
        }
        return ModelSelection.defaultGeminiModel
    }

    public static var documentOcrOpenRouterModel: String {
        if let saved = UserDefaults.standard.string(forKey: DefaultsKey.documentOCROpenRouterModel)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_DOC_OCR_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return "openbmb/minicpm-v-2_6"
    }

    // MARK: - Capability Mappings
    public static var thinkModelIdentifier: String { ModelSelection.model(for: .think) }
    public static var hearModelIdentifier: String { ModelSelection.model(for: .hear) }

    /// Resolve the user-selected transcription model and its engine from SharedUserDefaults.
    /// Returns nil when no model is configured (caller decides how to handle).
    public static func resolveTranscriptionSelection() -> (model: String, engine: EngineID)? {
        let shared = SharedUserDefaults.store
        let raw = (shared.string(forKey: DefaultsKey.capabilityHearModel)
            ?? shared.string(forKey: DefaultsKey.transcribeModel))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }

        let model = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
        let lower = model.lowercased()
        // Safety: "apple/on-device" and explicit native aliases must always route to native engine.
        if lower == "native" || lower == "apple" || lower == ModelSelection.appleModelIdentifier {
            return (model, .native)
        }

        // Engine is configured independently from model in UI.
        // Prefer shared defaults (for cross-process CLI/TUI), fallback to standard and sync it.
        let engineRaw: String? = {
            if let value = shared.string(forKey: DefaultsKey.transcriberEngine)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            if let value = UserDefaults.standard.string(forKey: DefaultsKey.transcriberEngine)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                shared.set(value, forKey: DefaultsKey.transcriberEngine)
                return value
            }
            return nil
        }()
        if let engineRaw, let engine = EngineID(rawValue: engineRaw), engine == .native {
            return (model, .native)
        }

        switch ModelRouter.provider(for: model) {
        case .gemini:
            return (model, .gemini)
        case .openrouter:
            return (model, .openrouter)
        case .apple:
            return (model, .native)
        case .local:
            return (model, .gemini)
        }
    }

    
    // Embedding configuration







    // Card visualization configuration
    public enum CardCfg {
        public static var textLimit: Int {
            let saved = UserDefaults.standard.integer(forKey: DefaultsKey.cardTextLimit)
            return saved > 0 ? saved : 2000
        }
    }
    
    // Agent configuration
    public static var agentMaxLoops: Int {
        let saved = UserDefaults.standard.integer(forKey: DefaultsKey.agentMaxLoops)
        return saved > 0 ? saved : 10
    }

    public static var agentRecursionDepth: Int {
        let saved = UserDefaults.standard.integer(forKey: DefaultsKey.agentRecursionDepth)
        return saved > 0 ? saved : 1
    }

    public static var agentToolsEnabled: Bool {
        if let val = UserDefaults.standard.object(forKey: DefaultsKey.agentToolsEnabled) as? Bool {
            return val
        }
        return true // Default ON
    }

    public static var agentMaxRetries: Int {
        if UserDefaults.standard.object(forKey: DefaultsKey.agentMaxRetries) == nil {
            return 2 // Default to 2 retries
        }
        return UserDefaults.standard.integer(forKey: DefaultsKey.agentMaxRetries)
    }

    public static var agentSearchLimit: Int {
        let saved = UserDefaults.standard.integer(forKey: DefaultsKey.agentSearchLimit)
        return saved > 0 ? saved : 20
    }

    // TTS configuration
    public enum TTSEngine: String {
        case native
    }

    public static var ttsEngine: TTSEngine {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.ttsEngine),
           let engine = TTSEngine(rawValue: raw) {
            return engine
        }
        return .native
    }


}




public enum AudioCfg {
    // 44.1 kHz is the only sampleRate that is suppoted by AVAudioRecorder on iOS/macOS
    // downsampling is performed before transcription.
    public static let sampleRate: Double = 44100
    public static let channels: Int = 1
    public static let bitRate: Int = 64_000
}

// Target parameters for reduced "mini" files used for transcription.
public enum TranscodeCfg {
    public static let miniSampleRate: Double = 16_000
    public static let miniBitRate: Int = 24_000 // 24 kbps AAC for _mini.m4a

    // MARK: - Micro audio (silence-trimmed upload copy)
    // `_micro.m4a` is a smaller sibling of `_mini.m4a`: same 16 kHz / 24 kbps target,
    // but with dead air (long pauses / room tone) removed so the cloud transcriber is
    // billed for fewer audio seconds. Only the upload copy is affected — the stored
    // original and the faithful mini are untouched. Deliberately conservative: the
    // trim floor sits *below* the quiet-speech band (~0.001–0.0035 RMS for this user)
    // so real speech survives, and the reencoder keeps generous padding around each
    // voiced run. If trimming would remove everything (a fully sub-floor file), micro
    // creation fails and transcription falls back to the mini / untrimmed original —
    // quiet speech is never lost to over-trimming.
    public static let microTrimDefaultRMSFloor: Double = 0.0008
    public static let microTrimMaxRMSFloor: Double = 0.02

    /// Whether a silence-trimmed `_micro.m4a` is produced and preferred for upload.
    /// Default on; when off, transcription uploads the mini (or original).
    public static var microAudioEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.microAudioEnabled) as? Bool ?? true
    }

    /// RMS floor (0...1) below which a ~100 ms window counts as silence and may be
    /// dropped from the micro copy. `0` (or the feature being disabled) means no micro
    /// is produced.
    public static var microTrimRMSFloor: Float {
        guard microAudioEnabled else { return 0 }
        let value: Double
        if UserDefaults.standard.object(forKey: DefaultsKey.microTrimRMSFloor) != nil {
            value = UserDefaults.standard.double(forKey: DefaultsKey.microTrimRMSFloor)
        } else {
            value = microTrimDefaultRMSFloor
        }
        return Float(min(max(value, 0), microTrimMaxRMSFloor))
    }
}

public enum RecordingCfg { 
    public static let toggleCooldown: TimeInterval = 0.4
    public static let minStreamingSilenceDuration: Double = 1.0
    public static let maxStreamingSilenceDuration: Double = 1000.0
    public static let minStreamingSplitActivationDelay: Double = 0.0
    public static let maxStreamingSplitActivationDelay: Double = 60.0
    public static let minStreamingSilenceLevelThreshold: Double = 0.01
    public static let maxStreamingSilenceLevelThreshold: Double = 0.25
    public static let defaultStreamingSilenceLevelThreshold: Double = 0.06
    /// Normalized audio-level threshold (0...1) below which input is treated as silence.
    public static var streamingSilenceLevelThreshold: Float {
        let value: Double
        if UserDefaults.standard.object(forKey: DefaultsKey.streamingSilenceLevelThreshold) != nil {
            value = UserDefaults.standard.double(forKey: DefaultsKey.streamingSilenceLevelThreshold)
        } else {
            value = defaultStreamingSilenceLevelThreshold
        }
        return Float(min(max(value, minStreamingSilenceLevelThreshold), maxStreamingSilenceLevelThreshold))
    }

    public static let minSilenceGateRMSFloor: Double = 0.0
    public static let maxSilenceGateRMSFloor: Double = 0.02
    public static let defaultSilenceGateRMSFloor: Double = 0.0035
    /// RMS amplitude (0...1) below which a finalized recording is treated as
    /// silent and skipped before transcription (defends against cloud-transcriber
    /// hallucinations on silence). `0` disables the acoustic gate. Higher values
    /// drop quieter recordings — a deliberately tunable speech/silence sensitivity.
    public static var silenceGateRMSFloor: Float {
        let value: Double
        if UserDefaults.standard.object(forKey: DefaultsKey.silenceGateRMSFloor) != nil {
            value = UserDefaults.standard.double(forKey: DefaultsKey.silenceGateRMSFloor)
        } else {
            value = defaultSilenceGateRMSFloor
        }
        return Float(min(max(value, minSilenceGateRMSFloor), maxSilenceGateRMSFloor))
    }

    /// Whether auto-save during recording is enabled
    public static var autoSaveEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.autoSaveRecordingEnabled) as? Bool ?? true
    }
    
    /// Auto-save interval in seconds (default: 5 seconds)
    public static var autoSaveInterval: Double {
        let saved = UserDefaults.standard.double(forKey: DefaultsKey.autoSaveRecordingInterval)
        return saved > 0 ? saved : 5.0
    }

    /// Silence duration in seconds before the HUD split countdown appears.
    public static var streamingSplitActivationDelay: Double {
        let value: Double
        if UserDefaults.standard.object(forKey: DefaultsKey.streamingSplitActivationDelay) != nil {
            value = UserDefaults.standard.double(forKey: DefaultsKey.streamingSplitActivationDelay)
        } else {
            value = 5.0
        }
        return min(max(value, minStreamingSplitActivationDelay), maxStreamingSplitActivationDelay)
    }

    /// Countdown duration in seconds after split activation before auto-splitting in streaming mode.
    public static var streamingSilenceDuration: Double {
        let raw = UserDefaults.standard.double(forKey: DefaultsKey.streamingSilenceDuration)
        let value = raw > 0 ? raw : 10.0
        return min(max(value, minStreamingSilenceDuration), maxStreamingSilenceDuration)
    }
}

public enum ProcessingCfg {
    public static var ocrEnabled: Bool {
        if let val = UserDefaults.standard.object(forKey: DefaultsKey.processingOCREnabled) as? Bool {
            return val
        }
        return true
    }

    public static var transcriptionEnabled: Bool {
        if let val = UserDefaults.standard.object(forKey: DefaultsKey.processingTranscriptionEnabled) as? Bool {
            return val
        }
        return true
    }

    public static var noteCardEnabled: Bool {
        get {
            if let val = SharedUserDefaults.store.object(forKey: DefaultsKey.processingNoteCardEnabled) as? Bool {
                return val
            }
            if let val = UserDefaults.standard.object(forKey: DefaultsKey.processingNoteCardEnabled) as? Bool {
                return val
            }
            return false
        }
        set {
            SharedUserDefaults.store.set(newValue, forKey: DefaultsKey.processingNoteCardEnabled)
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.processingNoteCardEnabled)
        }
    }

    /// Alias for noteCardEnabled (LLM analysis of notes).
    public static var analysisEnabled: Bool {
        get { noteCardEnabled }
        set { noteCardEnabled = newValue }
    }

    /// Auto-route questions from notes to chat agent. Default: OFF (experimental).
    public static var autoRouteEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.autoRouteEnabled)
    }
}

public enum TimingCfg { public static let seekStep: Double = 5.0 }

public enum TranscriptionCfg {
    public static let defaultInlineDataMaxMB: Double = 10.0
    public static let minInlineDataMaxMB: Double = 1.0
    public static let maxInlineDataMaxMB: Double = 100.0

    /// Maximum audio payload sent inline as Data/base64. Larger files should use
    /// provider upload APIs instead of a JSON inline-data request.
    public static var inlineDataMaxMB: Double {
        let raw: Double
        if let env = ProcessInfo.processInfo.environment["WIMM_TRANSCRIPTION_INLINE_DATA_MAX_MB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let value = Double(env),
           value.isFinite {
            raw = value
        } else if UserDefaults.standard.object(forKey: DefaultsKey.transcriptionInlineDataMaxMB) != nil {
            raw = UserDefaults.standard.double(forKey: DefaultsKey.transcriptionInlineDataMaxMB)
        } else {
            raw = defaultInlineDataMaxMB
        }
        return min(max(raw, minInlineDataMaxMB), maxInlineDataMaxMB)
    }

    public static var inlineDataMaxBytes: Int64 {
        Int64((inlineDataMaxMB * 1024 * 1024).rounded(.down))
    }

    public static var maxFileBytes: Int64 { inlineDataMaxBytes }
    public static let autoCopyEnabled: Bool = (ProcessInfo.processInfo.environment["WIMM_DISABLE_AUTO_COPY"] == nil)
    public static let minTranscriptWordsForScreenshotOCR: Int = 8
}

public enum NativeSpeechCfg {
    public static let maxRecommendedDuration: Double = 100 * 60

    public static let progressLogInterval: TimeInterval = 30 // log heartbeat while processing
}

public enum RealtimeEngine: String, CaseIterable, Identifiable {
    case native
    
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .native: return "Native (Apple)"
        }
    }
}

public extension Config {
    static var realtimeTranscriptionEngine: RealtimeEngine {
        get {
            if let raw = UserDefaults.standard.string(forKey: "WimmRealtimeEngine"),
               let engine = RealtimeEngine(rawValue: raw) {
                return engine
            }
            return .native
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "WimmRealtimeEngine")
        }
    }
}

public enum VADCfg {
    static let silenceDb = -52.0
    static let minSilence = 1.2
    static let minSpeech = 0.45
    static let frameLenSec = 0.02
}

// LLM/network related configuration
public enum LLMCfg {
    public enum Provider: String, Sendable { case gemini, openrouter, local, apple }

    /// Timeout in seconds for regular LLM JSON calls
    public static let requestTimeout: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["WIMM_LLM_TIMEOUT"], let v = Double(s) { return v }
        return 180
    }()
}

// Heads-up display configuration
