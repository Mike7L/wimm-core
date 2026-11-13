import Foundation

// Centralized keys for UserDefaults to avoid magic strings scattered across the codebase.
public enum DefaultsKey {
    public static let appLanguage = "appLanguage"
    public static let geminiApiKey = "GEMINI_API_KEY"
    public static let openRouterApiKey = "OPENROUTER_API_KEY"
    public static let transcriberEngine = "transcriberEngine"
    public static let filterOnlyMatches = "filterOnlyMatches"
    public static let filterFailedOnly = "filterFailedOnly"
    public static let filterSuspectedNoSpeechOnly = "filterSuspectedNoSpeechOnly"
    public static let filterWithScreenshotOnly = "filterWithScreenshotOnly"
    // Same string the Reader has always written; it just used to be a literal
    // at the one call site instead of a key here.
    public static let filterInsightsOnly = "filterInsightsOnly"
    public static let analysisModel = "analysisModel" // model for AnalysisCard/induction JSON LLM (Gemini or OpenRouter id)
    public static let transcribeModel = "transcribeModel" // Transcription model (Gemini id or OpenRouter model id)
    public static let documentOCREngine = "documentOCREngine" // "vision" | "mlx" | "gemini" | "minicpm"
    public static let documentOCRGeminiModel = "documentOCRGeminiModel"
    public static let documentOCROpenRouterModel = "documentOCROpenRouterModel"
    public nonisolated(unsafe) static var documentOCRPythonPath = "documentOCRPythonPath"
    
    // TTS
    public static let ttsEngine = "ttsEngine" // "native" | "local"
    public static let ttsLocalModel = "ttsLocalModel"
    public static let ttsLanguage = "ttsLanguage"


    public static let swiftDataEnabled = "WimmSwiftDataEnabled"
    public static let darkModeEnabled = "darkModeEnabled" // legacy: bool toggle for forcing Dark (true) or Light (false)
    public static let themeMode = "themeMode" // "system" | "light" | "dark"
    // Tuning knobs
    public static let searchDebounceMs = "searchDebounceMs" // Int (ms), default 150
    public static let cacheRegexLimit = "cacheRegexLimit"   // Int, default 128
    public static let cacheImageLimit = "cacheImageLimit"   // Int, default 256
    public static let cacheThumbnailLimit = "cacheThumbnailLimit" // Int, default 512
    public static let profilingEnabled = "profilingEnabled" // Bool or env WIMM_PROFILING=1
    public static let profilingAutoSaveIntervalMinutes = "profilingAutoSaveIntervalMinutes" // Double (minutes), default 15, <0 disables
    public static let readerDisplayMode = "readerDisplayMode" // Reader layout
    public static let cardTextLimit = "cardTextLimit" // Int (characters), default 2000
    public static let cardsVisualizationSettings = "cardsVisualizationSettings" // JSON: CardsVisualizationSettings
    
    // Persistence for state and previously non-saved settings
    public static let playbackRate = "playbackRate"
    public static let skipSilencePlayback = "skipSilencePlayback"
    public static let activeNoteId = "activeNoteId"
    public static let noteViewWidth = "noteViewWidth"
    public static let projectsPanelWidth = "projectsPanelWidth"
    public static let noteListWidth = "noteListWidth"
    public static let projectsPanelExpanded = "projectsPanelExpanded"
    public static let captureScreenshotScope = "captureScreenshotScope"
    
    
    // Private mode: pseudonymize note text before cloud LLM calls and refuse
    // cloud audio/OCR (Bool, default false; env WIMM_PRIVATE_MODE overrides).
    public static let privateMode = "privateMode"

    // Voice Memos auto-import (iPhone → iCloud → Wimm)
    public static let voiceMemosAutoImportEnabled = "voiceMemosAutoImportEnabled"

    // Recording Settings
    public static let autoSaveRecordingEnabled = "autoSaveRecordingEnabled"
    public static let autoSaveRecordingInterval = "autoSaveRecordingInterval"
    public static let streamingRecordingEnabled = "streamingRecordingEnabled"
    public static let streamingSplitActivationDelay = "streamingSplitActivationDelay"
    public static let streamingSilenceDuration = "streamingSilenceDuration"
    public static let streamingSilenceLevelThreshold = "streamingSilenceLevelThreshold"
    public static let silenceGateRMSFloor = "silenceGateRMSFloor"
    // Micro audio: a silence-trimmed `_micro.m4a` upload copy (smaller than mini) that
    // drops dead air before transcription to cut cloud audio-token duration. Affects
    // only the upload copy — the original and the faithful mini are untouched.
    public static let microAudioEnabled = "microAudioEnabled"
    public static let microTrimRMSFloor = "microTrimRMSFloor"

    // Artifact Visualization
    public static let showArtifacts = "showArtifacts"
    public static let highlightArtifacts = "highlightArtifacts"
    
    // CapturedNote Display
    public static let showCanceledNotes = "showCanceledNotes"
    
    // Search
    public static let emojisInSummary = "emojisInSummary"
    public static let llmResponseLanguage = "llmResponseLanguage"
    public static let transcriptionLanguage = "transcriptionLanguage"
    public static let transcriptionInlineDataMaxMB = "transcriptionInlineDataMaxMB"
    public static let smartModel = "smartModel" // Model for advanced reasoning (e.g. gemini-3.5-flash)

    // Capability-based model overrides
    public static let capabilityThinkModel = "capabilityThinkModel"
    public static let capabilityUnderstandModel = "capabilityUnderstandModel"
    public static let capabilityHearModel = "capabilityHearModel"
    public static let capabilitySeeModel = "capabilitySeeModel"
    
    // Agent
    public static let agentMaxLoops = "agentMaxLoops"
    public static let agentRecursionDepth = "agentRecursionDepth"
    public static let agentToolsEnabled = "agentToolsEnabled"
    public static let agentMaxRetries = "agentMaxRetries"
    public static let agentCustomInstructions = "agentCustomInstructions"
    public static let agentSearchLimit = "agentSearchLimit"
    public static let agentTextLengthCap = "agentTextLengthCap" // Int (characters), default 1200
    public static let agentProfile = "agentProfile"
    
    public static let llmLoggingEnabled = "llmLoggingEnabled"

    // Processing
    public static let processingOCREnabled = "processingOCREnabled"
    public static let processingTranscriptionEnabled = "processingTranscriptionEnabled"
    public static let processingNoteCardEnabled = "processingNoteCardEnabled"
    public static let autoRouteEnabled = "autoRouteEnabled"
    /// Seconds of silence after which a live recording closes its note (Double, 0 = off).
    public static let captureSilenceSplitSeconds = "captureSilenceSplitSeconds"
    public static let processingStatusNullToCompletedMigrationV1 = "processingStatusNullToCompletedMigrationV1"

}
