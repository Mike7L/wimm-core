import Foundation

/// When a live recording sends its note on silence. Nothing is cut out of the audio and nothing
/// is thrown away: the next note simply starts at once, and a silent one is left for the
/// secretary to drop.
public struct SilenceSplitPolicy: Sendable, Equatable {
    /// Ten seconds of quiet end the note.
    public static let defaultCloseAfterSeconds: Double = 10

    /// Silence that sends a note; 0 turns splitting off.
    public var closeAfterSeconds: Double = defaultCloseAfterSeconds
    /// Buffer RMS below this (≈ −54 dBFS, the live gate's floor) counts as quiet.
    public var quietRMS: Float = 0.002

    public init() {}

    public var isEnabled: Bool { closeAfterSeconds > 0 }

    /// The user's setting (`captureSilenceSplitSeconds`), the default when unset.
    public static func stored(_ defaults: UserDefaults = .standard) -> SilenceSplitPolicy {
        var policy = SilenceSplitPolicy()
        if let value = defaults.object(forKey: DefaultsKey.captureSilenceSplitSeconds) as? Double {
            policy.closeAfterSeconds = value < 0 ? 0 : value
        }
        return policy
    }
}

/// Sends only a note that contains speech, so an hour of silence stays one note, not sixty.
public struct SilenceSplitter: Sendable {
    public let policy: SilenceSplitPolicy
    private var heardSpeech = false
    private var quietFor = 0.0

    public init(policy: SilenceSplitPolicy) { self.policy = policy }

    /// A new note started (first one, or after a send): count from scratch.
    public mutating func restart() {
        heardSpeech = false
        quietFor = 0
    }

    /// One buffer's loudness and length; true when the note should be sent now.
    public mutating func feed(rms: Float, seconds: Double) -> Bool {
        guard policy.isEnabled else { return false }
        if rms >= policy.quietRMS {
            heardSpeech = true
            quietFor = 0
            return false
        }
        quietFor += seconds
        guard heardSpeech, quietFor >= policy.closeAfterSeconds else { return false }
        restart()
        return true
    }
}
