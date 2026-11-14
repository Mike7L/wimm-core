import AVFAudio
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
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { @Sendable _ in
                Task { @MainActor in
                    try? AVAudioApplication.shared.setInputMuted(false)
                    onPress()
                }
                return true
            }
        } catch {
            log("[Capture] AirPods press handler unavailable: \(error.localizedDescription)")
        }
    }
}
