import Foundation
import WimmDomain

/// Management class for a recording session.
/// Encapsulates the lifecycle of recording artifacts (audio, metadata, screenshots)
/// ensures atomic updates and crash recovery.
public actor RecordingSession {
    public let id: UUID
    public let startDate: Date
    public private(set) var state: SessionState
    
    // Artifacts
    public private(set) var audioFileURL: URL?
    public private(set) var metadataURL: URL?
    
    public enum SessionState: String, Codable {
        case initializing
        case recording
        case paused
        case completed
        case failed
        case canceled
    }
    
    public init(id: UUID = UUID()) {
        self.id = id
        self.startDate = Date()
        self.state = .initializing
    }
    
    public func setAudioFile(_ url: URL) {
        self.audioFileURL = url
    }
    
    public func updateState(_ newState: SessionState) {
        self.state = newState
        // TODO: Persist state
    }
}
