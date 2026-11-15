import AVFAudio
import Foundation
import WimmDomain

/// The AirPods stem press ("mute microphone") as a capture command: while recording it
/// sends the note (as ⌥X), while idle it starts recording (as ⌥W).
///
/// macOS asks the app that uses the microphone to honor the press through this handler;
/// without one it shows "Cannot Control Mic with AirPods". The press never mutes anything
/// here: the mute flag is cleared right after, so the next press arrives as a press again.
@MainActor
enum AirPodsCaptureGesture {
    static func install(onPress: @escaping @MainActor () -> Void) {
        do {
            // Called off the main thread: the closure must be @Sendable (see the Swift 6
            // callback trap), so it only hops to the main actor.
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { @Sendable muted in
                Task { @MainActor in
                    guard filter.accept(muted: muted, at: Date()) else { return }
                    try? AVAudioApplication.shared.setInputMuted(false)
                    onPress()
                }
                return true
            }
        } catch {
            log("[Capture] AirPods press handler unavailable: \(error.localizedDescription)")
        }
    }

    private static var filter = AirPodsPressFilter()
}

/// Tells a real stem press from the mute-state changes that follow it.
///
/// Only a change *to* muted is a press: the unmute Wimm sets itself, and the state changes
/// a microphone restart for the next note can bring, must never send that note. Repeats
/// within `minimumInterval` of an accepted press are dropped: each accepted press opens a new
/// note, so a burst of callbacks cannot cut a recording into sub-second notes.
struct AirPodsPressFilter {
    static let minimumInterval: TimeInterval = 2.0

    private var lastAccepted: Date?

    mutating func accept(muted: Bool, at now: Date) -> Bool {
        guard muted else { return false }
        if let lastAccepted, now.timeIntervalSince(lastAccepted) < Self.minimumInterval {
            log("[Capture] AirPods press ignored: repeat within \(Self.minimumInterval) s")
            return false
        }
        lastAccepted = now
        return true
    }
}
