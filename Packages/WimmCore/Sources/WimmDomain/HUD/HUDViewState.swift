import Foundation

public enum HUDMode: Sendable, Equatable {
    case idle
    case capture
    case review
}

public struct HUDViewState: Sendable, Equatable {
    public let snapshot: HUDSnapshot
    public let rootPath: String
    public let autoProcessAfterRecord: Bool
    public let recordingSince: Date?
    public let liveTranscriptPreview: String?
    public let reviewState: HUDReviewState?
    public let showHelp: Bool
    public let lastMessage: String

    public init(
        snapshot: HUDSnapshot,
        rootPath: String,
        autoProcessAfterRecord: Bool,
        recordingSince: Date?,
        liveTranscriptPreview: String?,
        reviewState: HUDReviewState?,
        showHelp: Bool,
        lastMessage: String
    ) {
        self.snapshot = snapshot
        self.rootPath = rootPath
        self.autoProcessAfterRecord = autoProcessAfterRecord
        self.recordingSince = recordingSince
        self.liveTranscriptPreview = liveTranscriptPreview
        self.reviewState = reviewState
        self.showHelp = showHelp
        self.lastMessage = lastMessage
    }

    public var mode: HUDMode {
        if recordingSince != nil { return .capture }
        if reviewState != nil { return .review }
        return .idle
    }
}
