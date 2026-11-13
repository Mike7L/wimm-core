import Foundation
import Combine

/// Protocol for an audio recording engine.
/// Implementations handle the specifics of AVAudioSession/AVAudioEngine configuration.
@MainActor
public protocol AudioRecorderProtocol: AnyObject {
    /// Whether the recorder is currently active
    var isRecording: Bool { get }
    
    /// Publishes instantaneous audio levels (normalized 0...1) for UI visualization
    var audioLevelsPublisher: AnyPublisher<[Float], Never> { get }
    
    /// Current duration of the recording in seconds.
    var duration: TimeInterval { get }
    
    /// Starts recording to a new file.
    /// - Returns: The URL of the file being recorded to.
    func startRecording() async throws -> URL
    
    /// Stops the recording and finalizes the file.
    /// - Returns: The URL of the completed recording.
    func stopRecording() async throws -> URL
    
    /// Cancels the current recording and cleans up artifacts if possible.
    func cancelRecording() async
}

/// Metadata associated with a recording session
public struct RecordingMetadata: Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var duration: TimeInterval
    public var projectID: String?
    
    public init(id: UUID = UUID(), startedAt: Date = Date(), duration: TimeInterval = 0, projectID: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.projectID = projectID
    }
}
