@preconcurrency import AVFoundation
import Foundation
import WimmInfrastructure

@MainActor
protocol VikVoicePlaying: AnyObject {
    var onIdle: (() -> Void)? { get set }
    var onStarted: (() -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func prepare()
    func enqueue(_ text: String)
    func stop()
}

/// Reuses Studio's local Supertonic player. A cold turn stays on the installed
/// Russian system voice; subsequent turns use the selected warmed voice.
@MainActor
final class VikVoice: NSObject, VikVoicePlaying, AVSpeechSynthesizerDelegate {
    static let voiceKey = "WimmStudio.vikVoice"
    static let voices = ShoulderSpeaker.availableFemaleVoices + ShoulderSpeaker.availableMaleVoices
    static var selectedVoice: String {
        get {
            let value = UserDefaults.standard.string(forKey: voiceKey) ?? "F4"
            return voices.contains(value) ? value : "F4"
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    var onIdle: (() -> Void)?
    var onStarted: (() -> Void)?
    var onFailure: (() -> Void)?
    private let neural = ShoulderVoicePlayer()
    private let system = AVSpeechSynthesizer()
    private var utterances: Set<ObjectIdentifier> = []
    private var index = 0
    private var useNeural: Bool?

    override init() {
        super.init()
        system.delegate = self
        neural.onIdle = { [weak self] in self?.onIdle?() }
        neural.onLineStarted = { [weak self] _ in self?.onStarted?() }
        neural.onFailure = { [weak self] in self?.onFailure?() }
    }

    func prepare() { neural.prepare() }

    func enqueue(_ text: String) {
        if useNeural == nil { useNeural = neural.isReady }
        // Citations stay visible in the HUD and saved reply, but aren't read aloud.
        let spoken = text.replacingOccurrences(of: #"\[(?:D\d+|b\d+|N:[A-Za-z0-9-]+)\]"#, with: "", options: .regularExpression)
        if useNeural == true {
            neural.enqueue(spoken, speaker: .demon, index: index,
                           voice: .init(Self.selectedVoice), speed: 1.16)
            index += 1
        } else {
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            utterance.rate = 0.5
            utterances.insert(ObjectIdentifier(utterance))
            system.speak(utterance)
        }
    }

    func stop() {
        utterances = []
        system.stopSpeaking(at: .immediate)
        neural.stop()
        useNeural = nil
        index = 0
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utterances.contains(id) else { return }
            self.onStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utterances.remove(id) != nil, self.utterances.isEmpty else { return }
            self.onIdle?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utterances.remove(id) != nil else { return }
            self.onFailure?()
        }
    }
}
