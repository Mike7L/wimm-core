import Foundation
import Combine
import WimmDomain

public enum LLMLogPhase: String, Codable, Sendable {
    case request
    case response
}

public struct LLMLog: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp = Date()
    public let model: String
    public let provider: String
    public let origin: String?
    public let attributes: [String: String]
    public let system: String?
    public let user: String
    public let response: String?
    public let error: String?
    public let isStreaming: Bool
    public let correlationId: UUID
    
    public init(model: String, provider: String, origin: String? = nil, attributes: [String: String] = [:], system: String?, user: String, response: String? = nil, error: String? = nil, isStreaming: Bool = false, correlationId: UUID = UUID()) {
        self.model = model
        self.provider = provider
        self.origin = origin
        self.attributes = attributes
        self.system = system
        self.user = user
        self.response = response
        self.error = error
        self.isStreaming = isStreaming
        self.correlationId = correlationId
    }
}

public struct LLMLogFileEntry: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let phase: LLMLogPhase
    public let model: String
    public let provider: String
    public let origin: String?
    public let attributes: [String: String]
    public let system: String?
    public let user: String
    public let response: String?
    public let error: String?
    public let isStreaming: Bool
    public let correlationId: UUID
}

public final class LLMLogger: @unchecked Sendable {
    public static let shared = LLMLogger()
    
    public let logSubject = PassthroughSubject<LLMLog, Never>()
    private let ioQueue = DispatchQueue(label: "wimm.llm.logger.io", qos: .utility)
    
    private init() {}
    
    private func enrichedAttributes(
        _ attributes: [String: String],
        model: String,
        provider: String,
        origin: String?,
        isStreaming: Bool
    ) -> [String: String] {
        var merged = attributes
        if merged["selected_model"] == nil { merged["selected_model"] = model }
        if merged["selected_provider"] == nil { merged["selected_provider"] = provider }
        if merged["route"] == nil { merged["route"] = isStreaming ? "stream" : "request_response" }
        if merged["origin_method"] == nil, let origin, !origin.isEmpty { merged["origin_method"] = origin }
        return merged
    }

    public func logRequest(model: String, provider: String, origin: String? = #function, attributes: [String: String] = [:], system: String?, user: String, isStreaming: Bool = false) -> UUID {
        let cid = UUID()
        let loggingEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.llmLoggingEnabled)
        let logAttrs = enrichedAttributes(attributes, model: model, provider: provider, origin: origin, isStreaming: isStreaming)
        UnifiedEventLogger.shared.logLLM(
            phase: LLMLogPhase.request.rawValue,
            correlationId: cid,
            model: model,
            provider: provider,
            origin: origin,
            attributes: logAttrs,
            isStreaming: isStreaming,
            system: loggingEnabled ? system : nil,
            user: loggingEnabled ? user : nil,
            response: nil,
            error: nil,
            source: "LLMLogger.logRequest"
        )
        guard loggingEnabled else { return cid }
        let log = LLMLog(model: model, provider: provider, origin: origin, attributes: logAttrs, system: system, user: user, isStreaming: isStreaming, correlationId: cid)
        logSubject.send(log)
        persistToJSON(log, phase: .request)
        return cid
    }
    
    public func logResponse(model: String, provider: String, origin: String? = #function, attributes: [String: String] = [:], system: String?, user: String, response: String?, error: String? = nil, isStreaming: Bool = false, correlationId: UUID) {
        let loggingEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.llmLoggingEnabled)
        let logAttrs = enrichedAttributes(attributes, model: model, provider: provider, origin: origin, isStreaming: isStreaming)
        UnifiedEventLogger.shared.logLLM(
            phase: LLMLogPhase.response.rawValue,
            correlationId: correlationId,
            model: model,
            provider: provider,
            origin: origin,
            attributes: logAttrs,
            isStreaming: isStreaming,
            system: loggingEnabled ? system : nil,
            user: loggingEnabled ? user : nil,
            response: loggingEnabled ? response : nil,
            error: error,
            source: "LLMLogger.logResponse"
        )
        guard loggingEnabled else { return }
        let log = LLMLog(model: model, provider: provider, origin: origin, attributes: logAttrs, system: system, user: user, response: response, error: error, isStreaming: isStreaming, correlationId: correlationId)
        logSubject.send(log)
        persistToJSON(log, phase: .response)
    }
    
    private func persistToJSON(_ log: LLMLog, phase: LLMLogPhase) {
        ioQueue.async {
            let logsDir = StoragePaths.baseDirectory()
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("llm", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
                
                let entry = LLMLogFileEntry(
                    id: log.id,
                    timestamp: log.timestamp,
                    phase: phase,
                    model: log.model,
                    provider: log.provider,
                    origin: log.origin,
                    attributes: log.attributes,
                    system: log.system,
                    user: log.user,
                    response: log.response,
                    error: log.error,
                    isStreaming: log.isStreaming,
                    correlationId: log.correlationId
                )
                
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                
                let data = try encoder.encode(entry)
                let millis = Int(log.timestamp.timeIntervalSince1970 * 1000)
                let fileName = "llm_\(millis)_\(phase.rawValue)_\(log.correlationId.uuidString.lowercased())_\(log.id.uuidString.lowercased()).json"
                let fileURL = logsDir.appendingPathComponent(fileName, isDirectory: false)
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                logDebug("LLMLogger file write failed: \(error.localizedDescription)")
            }
        }
    }
}
