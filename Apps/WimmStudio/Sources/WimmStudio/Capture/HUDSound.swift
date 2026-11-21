import AppKit
import WimmDocumentUI

/// Short, quiet cues for capture, Алёна and the HUD («Огонёк»). A cue must not land
/// in a note: while the microphone is open without headphones, cues that would
/// be recorded are skipped and the HUD confirms with light only.
@MainActor
enum HUDSound {
    enum Cue: String, CaseIterable {
        /// Recording starts; plays while the microphone is still opening.
        case start
        /// Recording stopped, the file is closed.
        case stop
        /// Quiet or ⌥S sent the note; recording goes on.
        case page
        /// Clipboard or screenshot saved.
        case saved
        /// Алёна heard her name; without headphones the note is already closed.
        case vikHeard
        /// Алёна finished; the microphone is the user's again.
        case vikDone
        case fail
        /// Recording is on but the input gives nothing; the note cannot record it.
        case trouble
        case lockOn
        case lockOff

        /// Cues that may come while the microphone records into a note.
        var needsHeadphonesWhileRecording: Bool {
            switch self {
            case .page, .saved, .lockOn, .lockOff: true
            case .start, .stop, .vikHeard, .vikDone, .fail, .trouble: false
            }
        }
    }

    static func shouldPlay(_ cue: Cue, recording: Bool, headphones: Bool, interfaceSounds: Bool) -> Bool {
        guard interfaceSounds else { return false }
        return !(cue.needsHeadphonesWhileRecording && recording && !headphones)
    }

    private static let sounds: [Cue: NSSound] = {
        var sounds: [Cue: NSSound] = [:]
        for cue in Cue.allCases {
            guard let sound = NSSound(data: HUDSoundSynth.wav(HUDSoundSynth.samples(for: cue))) else { continue }
            sounds[cue] = sound
        }
        return sounds
    }()

    static func preload() { _ = sounds }

    static func play(_ cue: Cue, recording: Bool, headphones: Bool) {
        guard shouldPlay(cue, recording: recording, headphones: headphones,
                         interfaceSounds: interfaceSoundsEnabled) else { return }
        guard let sound = sounds[cue] else { return }
        sound.stop()
        sound.play()
    }

    /// System Settings › Sound › «Play user interface sound effects».
    private static var interfaceSoundsEnabled: Bool {
        let value = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString,
                                              "com.apple.systemsound" as CFString)
        return (value as? NSNumber)?.boolValue ?? true
    }
}

/// Turns observed capture and Алёна state into cues. Start and stop come from
/// capture callbacks instead; this covers what only shows as a state change.
struct HUDCueTracker {
    struct Snapshot: Equatable {
        var recording = false
        var sendCount: UInt64 = 0
        var inputTrouble = false
        var vik: VikAssistant.Phase = .idle
        var headphones = false
    }

    private var last: Snapshot?
    private var troubleCued = false

    mutating func cues(for now: Snapshot) -> [HUDSound.Cue] {
        defer { last = now }
        if !now.recording { troubleCued = false }
        guard let last else { return [] }
        var cues: [HUDSound.Cue] = []
        // In headphones mode Алёна's address rolls the note over too; her own cue covers it.
        if now.sendCount > last.sendCount, now.recording, now.vik == .idle, last.vik == .idle { cues.append(.page) }
        if now.inputTrouble, !last.inputTrouble, now.recording, !troubleCued {
            troubleCued = true
            cues.append(.trouble)
        }
        if now.vik != last.vik {
            switch now.vik {
            case .failed: cues.append(.fail)
            // Without headphones the cue waits for the closed note (`stopCue`).
            case .finishing where now.headphones: cues.append(.vikHeard)
            // Without headphones the cue comes with the resumed capture (`startCue`).
            case .idle where now.headphones && (last.vik == .speaking || last.vik == .thinking): cues.append(.vikDone)
            default: break
            }
        }
        return cues
    }

    /// The microphone is opening: Алёна handing it back, or a plain start.
    static func startCue(vikResuming: Bool) -> HUDSound.Cue { vikResuming ? .vikDone : .start }

    /// The note closed: for Алёна's address that means she heard it.
    static func stopCue(vik: VikAssistant.Phase, headphones: Bool) -> HUDSound.Cue {
        vik == .finishing && !headphones ? .vikHeard : .stop
    }
}
