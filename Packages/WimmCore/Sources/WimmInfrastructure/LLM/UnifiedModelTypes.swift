import Foundation

public enum ModelPriority: Int, Comparable, Codable, Sendable {
    case background = 0
    case normal = 1
    case high = 2

    public static func < (lhs: ModelPriority, rhs: ModelPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

public enum ModelJobStatus: Equatable, Codable, Sendable {
    case queued
    case processing
    case completed
    case failed(String)
}

public enum ModelType: String, Codable, Sendable {
    case vision
    case transcription
    case processing  // Note extraction/summarization
    case chat         // Chat / agent LLM calls
    case analysis     // Card analysis LLM calls
    case other
}

public struct ModelJob: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: ModelType
    public let input: String  // URL absoluteString or text content
    public let priority: ModelPriority
    public var status: ModelJobStatus
    public var progress: Double?  // 0.0 to 1.0
    public var output: String?
    public let submittedAt: Date
    public let engine: String
    public let context: [String: String]?  // origin, reason, etc.

    public init(
        id: UUID = UUID(), type: ModelType, input: String, priority: ModelPriority = .normal,
        status: ModelJobStatus = .queued, progress: Double? = nil, output: String? = nil,
        submittedAt: Date = Date(), engine: String, context: [String: String]? = nil
    ) {
        self.id = id
        self.type = type
        self.input = input
        self.priority = priority
        self.status = status
        self.progress = progress
        self.output = output
        self.submittedAt = submittedAt
        self.engine = engine
        self.context = context
    }
    public var fileURL: URL? {
        if input.hasPrefix("file://") {
            return URL(string: input)
        }
        return nil
    }
}
