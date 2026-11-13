import AppKit

/// Short, quiet cues shared by all Studio capture entry points.
@MainActor
enum CaptureSoundFeedback {
    private static let sounds: [String: NSSound] = {
        var sounds: [String: NSSound] = [:]
        for name in ["Tink", "Pop"] {
            guard let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff",
                                      byReference: false) else { continue }
            sound.volume = 0.35
            sounds[name] = sound
        }
        return sounds
    }()

    static func preload() { _ = sounds }
    static func start() { play("Tink") }
    static func finish() { play("Pop") }

    private static func play(_ name: String) {
        guard let sound = sounds[name] else { return }
        sound.stop()
        sound.play()
    }
}
