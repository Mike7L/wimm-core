#if os(iOS)
import AVFoundation

/// What an `AVAudioSession.interruptionNotification` said, decoupled from
/// `userInfo` so the policy below is testable.
enum AudioInterruptionEvent: Equatable {
    case began
    case ended(shouldResume: Bool)

    init?(_ userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            self = .began
        case .ended:
            let options = (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            self = .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}

/// A phone call (or Siri, an alarm) closes the current note as if the user
/// pressed stop: an AAC file left paused through a long call is unreadable if
/// iOS kills the app meanwhile. After the call a new note starts, unless the
/// user had paused, iOS does not allow resuming, or the user already acted.
enum AudioInterruptionPolicy {
    enum Action: Equatable {
        case none
        /// Finish the current note; `restartAfter` is remembered for `.ended`.
        case finish(restartAfter: Bool)
        case startNewRecording
    }

    static func action(
        for event: AudioInterruptionEvent, isRecording: Bool, isUserPaused: Bool, restartPending: Bool
    ) -> Action {
        switch event {
        case .began:
            guard isRecording else { return .none }
            return .finish(restartAfter: !isUserPaused)
        case .ended(let shouldResume):
            guard restartPending, !isRecording, shouldResume else { return .none }
            return .startNewRecording
        }
    }
}
#endif
