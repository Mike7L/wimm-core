import Foundation

#if ENABLE_LOCAL_AI
public struct LocalLLMProvider: ModelProvider {
    public let capability: ModelCapability
    public let identifier: String
    public let provider: LLMCfg.Provider = .local
    
    public var metadata: [String: String] {
        [
            "provider": provider.rawValue,
            "model": identifier,
            "capability": capability.rawValue
        ]
    }
    
    public init(identifier: String, capability: ModelCapability = .think) {
        self.identifier = identifier
        self.capability = capability
    }
    
    public func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        let combined = "System:\n\(request.system)\n\nUser:\n\(request.user)"
        let modelId = LocalModelManager.normalizeIdentifier(identifier)
        let result = try await LocalModelManager.shared.generate(prompt: combined, modelIdentifier: modelId)
        if let tracer {
            await MainActor.run { tracer("\(request.traceTag)\n\(result)") }
        }
        return result
    }
}
#endif

struct DisabledLocalProvider: ModelProvider {
    let capability: ModelCapability
    let identifier: String
    let provider: LLMCfg.Provider = .local

    var metadata: [String: String] {
        [
            "provider": provider.rawValue,
            "model": identifier,
            "capability": capability.rawValue
        ]
    }

    init(identifier: String, capability: ModelCapability) {
        self.identifier = identifier
        self.capability = capability
    }

    func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        if let tracer {
            await MainActor.run { tracer("Local AI disabled (ENABLE_LOCAL_AI). Model \(identifier) unavailable.") }
        }
#if ENABLE_LOCAL_AI
        throw LocalModelError.localAISupportDisabled
#else
        throw NSError(domain: "WimmLocalAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Local AI disabled via build flag"])
#endif
    }
}

#if ENABLE_LOCAL_AI
public struct LocalVisionProvider: ModelProvider {
    public let capability: ModelCapability = .see
    public let identifier: String
    public let provider: LLMCfg.Provider = .local
    
    public var metadata: [String: String] {
        ["provider": provider.rawValue, "model": identifier, "capability": capability.rawValue]
    }
    
    public init(identifier: String) {
        self.identifier = identifier
    }
    
    public func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        // Support for MLX VLM (e.g. Qwen2-VL)
        let combined = "System:\n\(request.system)\n\nUser:\n\(request.user)"
        let modelId = LocalModelManager.normalizeIdentifier(identifier)
        // For now, we reuse LocalModelManager. If VLM specific logic is needed, 
        // it would be added to LocalModelManager.
        let result = try await LocalModelManager.shared.generate(prompt: combined, modelIdentifier: modelId)
        if let tracer {
            await MainActor.run { tracer("\(request.traceTag)\n\(result)") }
        }
        return result
    }
}
#endif

