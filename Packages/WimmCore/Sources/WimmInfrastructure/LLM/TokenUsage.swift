import Foundation

/// Token counters as reported by the provider for a single call.
///
/// Every field is optional on purpose: a missing counter means "the provider
/// did not say", which is different from zero. Cost estimation skips unknown
/// fields rather than treating them as free.
///
/// `audioTokens` / `cachedInputTokens` are carved out of `inputTokens` by both
/// providers (Gemini reports them inside `promptTokensDetails`), so they are
/// *breakdowns*, not additional charges — summing them into the input count
/// would double-bill the audio, which is the single most expensive modality
/// here.
///
/// `thoughtsTokens` is the opposite: Gemini reports its hidden reasoning
/// (`thoughtsTokenCount`) *outside* `candidatesTokenCount` and bills it at the
/// output rate, so it is an addition to the output, not a part of it.
public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var cachedInputTokens: Int?
    public var audioTokens: Int?
    public var thoughtsTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        audioTokens: Int? = nil,
        thoughtsTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.audioTokens = audioTokens
        self.thoughtsTokens = thoughtsTokens
    }

    public var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil && totalTokens == nil
            && cachedInputTokens == nil && audioTokens == nil && thoughtsTokens == nil
    }

    /// Text-only input, i.e. what is billed at the plain input rate once the
    /// separately-priced modalities are taken out.
    public var textInputTokens: Int? {
        guard let inputTokens else { return nil }
        return max(0, inputTokens - (audioTokens ?? 0) - (cachedInputTokens ?? 0))
    }

    /// Reasoning tokens to bill. Records written before `tokens_thoughts`
    /// existed still carry the total, and for Gemini `total − in − out` is the
    /// thinking; OpenRouter's total is exactly in + out, so it yields nothing.
    /// ``thoughtsAreEstimated`` says which of the two this is.
    public var billedThoughtsTokens: Int? {
        if let thoughtsTokens { return thoughtsTokens }
        guard let totalTokens, let inputTokens, let outputTokens else { return nil }
        let rest = totalTokens - inputTokens - outputTokens
        return rest > 0 ? rest : nil
    }

    public var thoughtsAreEstimated: Bool {
        thoughtsTokens == nil && billedThoughtsTokens != nil
    }

    /// Flattened into the `attributes` bag of the unified event log. Keys are
    /// stable — `wimm-cli cost` parses them back out, so renaming one silently
    /// drops history.
    public var logAttributes: [String: String] {
        var attrs: [String: String] = [:]
        if let inputTokens { attrs["tokens_in"] = String(inputTokens) }
        if let outputTokens { attrs["tokens_out"] = String(outputTokens) }
        if let totalTokens { attrs["tokens_total"] = String(totalTokens) }
        if let cachedInputTokens { attrs["tokens_cached_in"] = String(cachedInputTokens) }
        if let audioTokens { attrs["tokens_audio"] = String(audioTokens) }
        if let thoughtsTokens { attrs["tokens_thoughts"] = String(thoughtsTokens) }
        return attrs
    }

    /// Inverse of ``logAttributes`` for readers of the event log.
    public init?(logAttributes attrs: [String: String]) {
        func int(_ key: String) -> Int? { attrs[key].flatMap(Int.init) }
        self.init(
            inputTokens: int("tokens_in"),
            outputTokens: int("tokens_out"),
            totalTokens: int("tokens_total"),
            cachedInputTokens: int("tokens_cached_in"),
            audioTokens: int("tokens_audio"),
            thoughtsTokens: int("tokens_thoughts")
        )
        if isEmpty { return nil }
    }
}

/// Reasoning tokens summed over many calls, keeping what the provider reported
/// apart from what was derived from an old record's total.
public struct ThoughtsTally: Sendable, Equatable {
    public var reported = 0
    public var estimated = 0

    public init(reported: Int = 0, estimated: Int = 0) {
        self.reported = reported
        self.estimated = estimated
    }

    public init<S: Sequence>(_ usages: S) where S.Element == TokenUsage {
        self.init()
        for usage in usages { add(usage) }
    }

    public var total: Int { reported + estimated }

    public mutating func add(_ usage: TokenUsage) {
        guard let count = usage.billedThoughtsTokens else { return }
        if usage.thoughtsAreEstimated { estimated += count } else { reported += count }
    }
}

/// Names for the kind of work an LLM call was doing, logged as the `operation`
/// attribute. Cost reporting groups by this, so the vocabulary has to stay
/// small and stable.
public enum LLMOperation: String, Sendable {
    case transcribe
    case refine
    case card
    case ocr
    case search
    case agent
    /// Live spoken conversation in Studio (the angel-and-demon window).
    case conversation
    case other
}
