import Foundation

// MARK: - Apple Foundation Models Provider (iOS 26+ / macOS 26+)
//
// Uses Apple's on-device LLM via the FoundationModels framework.
// Supports .think and .understand capabilities — text generation and structured JSON output.
// Falls back gracefully when the framework is unavailable (older OS or unsupported hardware).

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
public struct AppleFoundationModelProvider: ModelProvider {
    public let capability: ModelCapability
    public let identifier: String
    public let provider: LLMCfg.Provider = .apple

    public var metadata: [String: String] {
        [
            "provider": provider.rawValue,
            "model": identifier,
            "capability": capability.rawValue,
            "runtime": "on-device"
        ]
    }

    public init(identifier: String = "apple/on-device", capability: ModelCapability) {
        self.identifier = identifier
        self.capability = capability
    }

    // MARK: - Availability

    /// Check if Apple on-device model is available on this device.
    public static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: - ModelProvider

    public func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        let model = SystemLanguageModel.default

        guard model.isAvailable else {
            throw NSError(
                domain: "AppleFoundationModel",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple on-device model not available on this device"]
            )
        }

        let session = LanguageModelSession()

        // Build combined prompt (system + user)
        let fullPrompt: String
        if request.system.isEmpty {
            fullPrompt = request.user
        } else {
            fullPrompt = """
            Instructions: \(request.system)

            \(request.user)
            """
        }

        if let tracer {
            await MainActor.run { tracer("Apple FM request (\(capability.rawValue))…") }
        }

        let response = try await session.respond(to: fullPrompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if let tracer {
            await MainActor.run { tracer("\(request.traceTag)\n\(text)") }
        }

        if text.isEmpty {
            throw NSError(
                domain: "AppleFoundationModel",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Apple on-device model returned empty response"]
            )
        }

        return text
    }
}
#endif

// MARK: - Fallback stub for older platforms

/// Stub provider returned when Apple Foundation Models are not available.
public struct UnavailableAppleProvider: ModelProvider {
    public let capability: ModelCapability
    public let identifier: String
    public let provider: LLMCfg.Provider = .apple

    public var metadata: [String: String] {
        [
            "provider": provider.rawValue,
            "model": identifier,
            "capability": capability.rawValue,
            "status": "unavailable"
        ]
    }

    public init(identifier: String = "apple/on-device", capability: ModelCapability) {
        self.identifier = identifier
        self.capability = capability
    }

    public func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        if let tracer {
            await MainActor.run {
                tracer("Apple Foundation Models unavailable (requires iOS 26+ / macOS 26+ with A17 Pro or M1+)")
            }
        }
        throw NSError(
            domain: "AppleFoundationModel",
            code: -2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Apple Foundation Models require iOS 26+ / macOS 26+ on A17 Pro / M1+ hardware"
            ]
        )
    }
}

// MARK: - Factory helper

public enum AppleModelFactory {
    /// Create the best available Apple provider, or the unavailable stub.
    public static func create(identifier: String = "apple/on-device", capability: ModelCapability) -> ModelProvider {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleFoundationModelProvider(identifier: identifier, capability: capability)
        }
        #endif
        return UnavailableAppleProvider(identifier: identifier, capability: capability)
    }

    /// Returns true if the on-device model is available at runtime.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleFoundationModelProvider.isAvailable
        }
        #endif
        return false
    }
}
