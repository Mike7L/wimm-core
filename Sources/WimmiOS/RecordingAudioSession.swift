#if os(iOS)
import Foundation
import AVFoundation
import WimmDomain
import WimmInfrastructure

/// Which microphone a voice recording may use.
enum RecordingMicrophonePreference: String, CaseIterable, Identifiable {
    /// AirPods or another Bluetooth headset (HFP) when connected, else the iPhone mic.
    case bluetoothWhenConnected
    /// Always the iPhone's built-in mic, even with a headset connected.
    case builtInOnly

    static let defaultsKey = "ios.recording.microphonePreference"
    static let `default`: RecordingMicrophonePreference = .bluetoothWhenConnected

    var id: String { rawValue }

    /// Stored in the App Group defaults like the other iOS settings.
    static func load(from defaults: UserDefaults = SharedUserDefaults.store) -> RecordingMicrophonePreference {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .default
    }

    func save(to defaults: UserDefaults = SharedUserDefaults.store) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Trial: record through iOS voice processing, so the system microphone modes
/// (Voice Isolation, Wide Spectrum) apply to the recording. Off by default.
/// With it on, the original file is the processed audio (noise suppression,
/// automatic gain); the unprocessed sound is not kept.
enum RecordingVoiceIsolationSetting {
    static let defaultsKey = "ios.recording.voiceIsolation"

    static func isEnabled(defaults: UserDefaults = SharedUserDefaults.store) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func set(_ enabled: Bool, defaults: UserDefaults = SharedUserDefaults.store) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// The one place that configures `AVAudioSession` for voice capture. The file
/// recorder and the live transcriber share the session, so they must never set
/// their own category (the later call used to overwrite the earlier one).
enum RecordingAudioSession {
    struct Plan: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        /// Pin the input to the built-in mic so iOS never picks a headset.
        let pinBuiltInMic: Bool
    }

    /// Pure: the session settings for a preference. `.measurement` + `.duckOthers`
    /// are what the live transcriber used before; they stay unchanged here.
    /// With `voiceProcessing` the session asks iOS for voice processing
    /// (`.playAndRecord` + `.videoChat`; `.measurement` turns it off), which is
    /// what makes the system microphone modes available.
    static func plan(for preference: RecordingMicrophonePreference, voiceProcessing: Bool = false) -> Plan {
        let base = basePlan(for: preference)
        guard voiceProcessing else { return base }
        return Plan(category: .playAndRecord, mode: .videoChat,
                    options: base.options, pinBuiltInMic: base.pinBuiltInMic)
    }

    private static func basePlan(for preference: RecordingMicrophonePreference) -> Plan {
        switch preference {
        case .bluetoothWhenConnected:
            return Plan(category: .record, mode: .measurement,
                        options: [.duckOthers, .allowBluetoothHFP], pinBuiltInMic: false)
        case .builtInOnly:
            return Plan(category: .record, mode: .measurement,
                        options: [.duckOthers], pinBuiltInMic: true)
        }
    }

    /// Inputs that count as headphones: Bluetooth (HFP/LE) first, then a wired headset.
    static let headsetPorts: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothLE, .headsetMic]

    /// Pure: the input type to prefer among the available ones (`nil` = let iOS
    /// route). Built-in-only pins the iPhone mic; the headset choice names the
    /// headset explicitly, so switching back from the iPhone mic mid-recording
    /// really moves the input instead of leaving the old pin in place.
    static func preferredPort(for plan: Plan, among ports: [AVAudioSession.Port]) -> AVAudioSession.Port? {
        if plan.pinBuiltInMic {
            return ports.contains(.builtInMic) ? .builtInMic : nil
        }
        return headsetPorts.first { ports.contains($0) }
    }

    /// Pure: whether the recording screen offers the headset ↔ iPhone switch.
    /// With the built-in-only plan Bluetooth is not allowed, so iOS does not list
    /// AirPods among the inputs; the switch back then stays available (with no
    /// headset it just keeps the iPhone mic).
    static func canSwitchMicrophone(preference: RecordingMicrophonePreference,
                                    availablePorts: [AVAudioSession.Port]) -> Bool {
        preference == .builtInOnly || availablePorts.contains { headsetPorts.contains($0) }
    }

    /// Configure and activate the session for recording.
    /// Voice processing of the running recording, read once at activation so a
    /// settings change mid-recording does not change the session under it.
    nonisolated(unsafe) private(set) static var voiceProcessingActive = false

    static func activate(preference: RecordingMicrophonePreference = .load(),
                         voiceProcessing: Bool = RecordingVoiceIsolationSetting.isEnabled()) throws {
        let session = AVAudioSession.sharedInstance()
        let plan = plan(for: preference, voiceProcessing: voiceProcessing)
        try session.setCategory(plan.category, mode: plan.mode, options: plan.options)
        try session.setActive(true)
        voiceProcessingActive = voiceProcessing
        applyPreferredInput(plan: plan)
        log("[IOSRecording] session active mic=\(preference.rawValue) voiceProcessing=\(voiceProcessing) micMode=\(activeMicrophoneModeName()) input=\(currentInputDescription())")
    }

    /// The system microphone mode now in effect (standard / voiceIsolation / wideSpectrum).
    static func activeMicrophoneModeName() -> String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "standard"
        case .voiceIsolation: return "voiceIsolation"
        case .wideSpectrum: return "wideSpectrum"
        @unknown default: return "unknown"
        }
    }

    /// Open the system sheet where the user picks Voice Isolation etc.
    static func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// Switch the microphone while a recording runs: apply the new plan to the
    /// already active session and keep it as the setting. The session stays
    /// active; the recorder and the live transcriber follow the route change
    /// they are notified of. The setting is saved only if the session took it.
    static func switchActiveSession(to preference: RecordingMicrophonePreference) throws {
        let session = AVAudioSession.sharedInstance()
        let plan = plan(for: preference, voiceProcessing: voiceProcessingActive)
        if session.category != plan.category || session.mode != plan.mode
            || session.categoryOptions != plan.options {
            try session.setCategory(plan.category, mode: plan.mode, options: plan.options)
        }
        applyPreferredInput(plan: plan)
        preference.save()
        log("[IOSRecording] mic switched to \(preference.rawValue) input=\(currentInputDescription())")
    }

    /// Re-pin the preferred input after a route change (a wired headset can still
    /// take over the input when Bluetooth is off).
    static func reapplyPreferredInput(preference: RecordingMicrophonePreference = .load()) {
        applyPreferredInput(plan: plan(for: preference, voiceProcessing: voiceProcessingActive))
    }

    static func availableInputPorts() -> [AVAudioSession.Port] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).map(\.portType)
    }

    private static func applyPreferredInput(plan: Plan) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let port = preferredPort(for: plan, among: inputs.map(\.portType))
        let target = port.flatMap { port in inputs.first { $0.portType == port } }
        guard session.preferredInput?.uid != target?.uid else { return }
        do {
            try session.setPreferredInput(target)
        } catch {
            log("[IOSRecording] setPreferredInput failed: \(error.localizedDescription)")
        }
    }

    static func currentInputDescription() -> String {
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return "none" }
        return "\(input.portName) (\(input.portType.rawValue))"
    }

    static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        default: return "unknown(\(reason.rawValue))"
        }
    }
}

/// One input the recording used, kept in the sidecar under `audioInputChanges`
/// (the start input stays in `audioInput`, written by `RecordingInputDevice`).
struct RecordingInputChange: Equatable {
    static let metadataKey = "audioInputChanges"
    let offset: TimeInterval
    let name: String
    let transport: String
    let reason: String

    var sidecarValue: [String: Any] {
        ["offsetSeconds": (offset * 10).rounded() / 10, "name": name,
         "transport": transport, "reason": reason]
    }
}
#endif
