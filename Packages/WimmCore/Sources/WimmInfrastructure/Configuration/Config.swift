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

    public static func model(for capability: ModelCapability) -> String {
        ModelSelection.model(for: capability)
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

    // MARK: - Agent

    public static var agentMaxRetries: Int {
        if UserDefaults.standard.object(forKey: DefaultsKey.agentMaxRetries) == nil {
            return 2 // Default to 2 retries
        }
        return UserDefaults.standard.integer(forKey: DefaultsKey.agentMaxRetries)
    }

}

public enum AudioCfg {
    // 44.1 kHz is the only sampleRate that is suppoted by AVAudioRecorder on iOS/macOS
    // downsampling is performed before transcription.
    public static let sampleRate: Double = 44100
    public static let channels: Int = 1
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

public enum ProcessingCfg {
    public static var ocrEnabled: Bool {
        if let val = UserDefaults.standard.object(forKey: DefaultsKey.processingOCREnabled) as? Bool {
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

}

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
