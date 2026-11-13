// Compiled only when SwiftData is enabled and the SwiftData framework is available (Xcode toolchain),
// and not under SPM tests (which lack macro support in some environments).
#if SWIFTDATA_ENABLED && canImport(SwiftData) && !SPM_TESTS
import Foundation
import SwiftData

@Model
public final class NoteMetaEntity {
    @Attribute(.unique) public var id: String
    public var title: String
    public var path: String
    public var tags: [String]
    public var isLiked: Bool
    public var isCanceled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AgentMessageEntity.note)
    public var agentMessages: [AgentMessageEntity] = []

    public init(id: String, title: String, path: String, tags: [String], isLiked: Bool = false, isCanceled: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.path = path
        self.tags = tags
        self.isLiked = isLiked
        self.isCanceled = isCanceled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
public final class AgentMessageEntity {
    @Attribute(.unique) public var id: String
    public var agentName: String
    public var inputJSON: String
    public var outputJSON: String
    public var timingMs: Int
    public var confidence: Double
    public var artifacts: [String]
    public var createdAt: Date

    @Relationship public var note: NoteMetaEntity?

    public init(id: String, agentName: String, inputJSON: String, outputJSON: String, timingMs: Int, confidence: Double, artifacts: [String], createdAt: Date, note: NoteMetaEntity? = nil) {
        self.id = id
        self.agentName = agentName
        self.inputJSON = inputJSON
        self.outputJSON = outputJSON
        self.timingMs = timingMs
        self.confidence = confidence
        self.artifacts = artifacts
        self.createdAt = createdAt
        self.note = note
    }
}

#endif
