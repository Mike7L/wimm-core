import Foundation

// Centralized keys for UserDefaults to avoid magic strings scattered across the codebase.
public enum DefaultsKey {
    public static let appLanguage = "appLanguage"
    public static let analysisModel = "analysisModel" // model for AnalysisCard/induction JSON LLM (Gemini or OpenRouter id)
    public static let transcribeModel = "transcribeModel" // Transcription model (Gemini id or OpenRouter model id)
    public static let documentOCREngine = "documentOCREngine" // "vision" | "mlx" | "gemini" | "minicpm"
    public static let documentOCRGeminiModel = "documentOCRGeminiModel"
    public static let documentOCROpenRouterModel = "documentOCROpenRouterModel"
    
    public static let ttsLanguage = "ttsLanguage"

    public static let profilingEnabled = "profilingEnabled" // Bool or env WIMM_PROFILING=1
    
    public static let skipSilencePlayback = "skipSilencePlayback"
    public static let activeNoteId = "activeNoteId"

    // Private mode: pseudonymize note text before cloud LLM calls and refuse
    // cloud audio/OCR (Bool, default false; env WIMM_PRIVATE_MODE overrides).
    public static let privateMode = "privateMode"

    // Micro audio: a silence-trimmed `_micro.m4a` upload copy (smaller than mini) that
    // drops dead air before transcription to cut cloud audio-token duration. Affects
    // only the upload copy — the original and the faithful mini are untouched.
    public static let microAudioEnabled = "microAudioEnabled"
    public static let microTrimRMSFloor = "microTrimRMSFloor"

    // Artifact Visualization
    public static let showArtifacts = "showArtifacts"
    
    // CapturedNote Display
    public static let showCanceledNotes = "showCanceledNotes"
    
    public static let transcriptionLanguage = "transcriptionLanguage"
    public static let transcriptionInlineDataMaxMB = "transcriptionInlineDataMaxMB"
    public static let smartModel = "smartModel" // Model for advanced reasoning (e.g. gemini-3.5-flash)

    // Capability-based model overrides
    public static let capabilityThinkModel = "capabilityThinkModel"
    public static let capabilityUnderstandModel = "capabilityUnderstandModel"
    public static let capabilityHearModel = "capabilityHearModel"
    public static let capabilitySeeModel = "capabilitySeeModel"
    
    public static let agentMaxRetries = "agentMaxRetries"
    
    public static let llmLoggingEnabled = "llmLoggingEnabled"

    // Processing
    public static let processingOCREnabled = "processingOCREnabled"
    public static let processingNoteCardEnabled = "processingNoteCardEnabled"
    /// Seconds of silence after which a live recording closes its note (Double, 0 = off).
    public static let captureSilenceSplitSeconds = "captureSilenceSplitSeconds"

}
