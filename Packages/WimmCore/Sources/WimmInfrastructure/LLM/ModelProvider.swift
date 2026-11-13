import Foundation

public struct ModelRequest: @unchecked Sendable {
    public let system: String
    public let user: String
    public let temperature: Double
    public let schema: [String: Any]?
    public let timeout: TimeInterval
    public let responseMimeType: String
    public let traceTag: String

    public init(
        system: String,
        user: String,
        temperature: Double,
        schema: [String: Any]?,
        timeout: TimeInterval,
        responseMimeType: String,
        traceTag: String
    ) {
        self.system = system
        self.user = user
        self.temperature = temperature
        self.schema = schema
        self.timeout = timeout
        self.responseMimeType = responseMimeType
        self.traceTag = traceTag
    }
}

/// A provider's answer plus whatever it reported about its own cost.
///
/// `usage` is nil for providers that bill nothing (local, Apple on-device) or
/// that did not return counters; a nil is "unknown", not "free" — the cost
/// aggregator must keep the two apart.
public struct ModelResponse: Sendable {
    public let text: String
    public let usage: TokenUsage?

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

public protocol ModelProvider: Sendable {
    var capability: ModelCapability { get }
    var identifier: String { get } // "gemini-3-flash" or "local/mlx-community/qwen2.5-1.5b"
    var provider: LLMCfg.Provider { get }
    var metadata: [String: String] { get }

    func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String

    /// Same call as ``perform(request:tracer:)`` but keeps the provider's token
    /// counters. Only the metered remote providers implement it; everything
    /// else inherits the default and reports no usage.
    func performDetailed(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> ModelResponse
}

extension ModelProvider {
    public func performDetailed(
        request: ModelRequest,
        tracer: (@Sendable (String) -> Void)?
    ) async throws -> ModelResponse {
        ModelResponse(text: try await perform(request: request, tracer: tracer))
    }
}
