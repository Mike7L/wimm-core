import Foundation

/// Stops a recognizer from spinning when replacement sessions repeatedly end
/// immediately. Platform adapters own the actual Speech task lifecycle; this
/// value only decides whether another session should be started.
public struct SessionRestartPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case restart
        case giveUp
    }

    public let rapidRestartInterval: TimeInterval
    public let maximumConsecutiveRapidRestarts: Int
    public private(set) var consecutiveRapidRestarts = 0

    private var lastSessionEndAt: Date?

    public init(
        rapidRestartInterval: TimeInterval = 1.0,
        maximumConsecutiveRapidRestarts: Int = 5
    ) {
        precondition(rapidRestartInterval >= 0)
        precondition(maximumConsecutiveRapidRestarts > 0)
        self.rapidRestartInterval = rapidRestartInterval
        self.maximumConsecutiveRapidRestarts = maximumConsecutiveRapidRestarts
    }

    public mutating func registerSessionEnd(at now: Date = Date()) -> Decision {
        if let lastSessionEndAt,
           now.timeIntervalSince(lastSessionEndAt) < rapidRestartInterval {
            consecutiveRapidRestarts += 1
        } else {
            consecutiveRapidRestarts = 0
        }
        lastSessionEndAt = now

        return consecutiveRapidRestarts >= maximumConsecutiveRapidRestarts
            ? .giveUp
            : .restart
    }

    public mutating func reset() {
        lastSessionEndAt = nil
        consecutiveRapidRestarts = 0
    }
}
