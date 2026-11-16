import AVFAudio
import Foundation
import WimmDomain

/// The AirPods stem press ("mute microphone") as a capture command: while recording it
/// sends the note (as ⌥X), while idle it starts recording (as ⌥W).
///
/// macOS asks the app that uses the microphone to honor the press through this handler;
/// without one it shows "Cannot Control Mic with AirPods". The press never mutes anything
/// here: the mute flag is cleared right after, so the next press arrives as a press again.
///
/// A handler alone is not enough: the audio server passes a press on only to an app that
/// has also set its mute state itself (its log says `isOptedIn: 0, hasHandler: 1`
/// otherwise). So Wimm states "unmuted" at install and again when a recording starts.
@MainActor
enum AirPodsCaptureGesture {
    static func install(onPress: @escaping @MainActor () -> Void) {
        do {
            // Called off the main thread: the closure must be @Sendable (see the Swift 6
            // callback trap), so it only hops to the main actor.
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { @Sendable muted in
                Task { @MainActor in
                    let now = Date()
                    guard filter.accept(muted: muted, at: now) else {
                        // A recording start arrives here as "unmuted".
                        if !muted, filter.shouldStateUnmuted(at: now) { stateUnmuted() }
                        return
                    }
                    _ = filter.shouldStateUnmuted(at: now)
                    stateUnmuted()
                    onPress()
                }
                return true
            }
            _ = filter.shouldStateUnmuted(at: Date())
            stateUnmuted()
        } catch {
            log("[Capture] AirPods press handler unavailable: \(error.localizedDescription)")
        }
    }

    private static var filter = AirPodsPressFilter()

    private static func stateUnmuted() {
        do {
            try AVAudioApplication.shared.setInputMuted(false)
        } catch {
            log("[Capture] AirPods: could not state unmuted: \(error.localizedDescription)")
        }
    }
}

/// Tells a real stem press from the mute-state changes that follow it.
///
/// Only a change *to* muted is a press: the unmute Wimm sets itself, and the state changes
/// a microphone restart for the next note can bring, must never send that note. Repeats
/// within `minimumInterval` of an accepted press are dropped: each accepted press opens a new
/// note, so a burst of callbacks cannot cut a recording into sub-second notes.
struct AirPodsPressFilter {
    static let minimumInterval: TimeInterval = 2.0

    /// Stating "unmuted" calls the handler back with "unmuted": answering every such
    /// callback would never end, so at most one statement per window.
    static let statementInterval: TimeInterval = 5.0

    private var lastAccepted: Date?
    private var lastStatement: Date?

    mutating func shouldStateUnmuted(at now: Date) -> Bool {
        if let lastStatement, now.timeIntervalSince(lastStatement) < Self.statementInterval { return false }
        lastStatement = now
        return true
    }

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
