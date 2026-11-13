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
    static func plan(for preference: RecordingMicrophonePreference) -> Plan {
        switch preference {
        case .bluetoothWhenConnected:
            return Plan(category: .record, mode: .measurement,
                        options: [.duckOthers, .allowBluetoothHFP], pinBuiltInMic: false)
        case .builtInOnly:
            return Plan(category: .record, mode: .measurement,
                        options: [.duckOthers], pinBuiltInMic: true)
        }
    }

    /// Pure: the input to prefer among the available ones (`nil` = let iOS route).
    static func preferredInput(for plan: Plan, among inputs: [AVAudioSessionPortDescription]) -> AVAudioSessionPortDescription? {
        guard plan.pinBuiltInMic else { return nil }
        return inputs.first { $0.portType == .builtInMic }
    }

    /// Configure and activate the session for recording.
    static func activate(preference: RecordingMicrophonePreference = .load()) throws {
        let session = AVAudioSession.sharedInstance()
        let plan = plan(for: preference)
        try session.setCategory(plan.category, mode: plan.mode, options: plan.options)
        try session.setActive(true)
        applyPreferredInput(plan: plan)
        log("[IOSRecording] session active mic=\(preference.rawValue) input=\(currentInputDescription())")
    }

    /// Re-pin the built-in mic after a route change (a wired headset can still
    /// take over the input when Bluetooth is off).
    static func reapplyPreferredInput(preference: RecordingMicrophonePreference = .load()) {
        applyPreferredInput(plan: plan(for: preference))
    }

    private static func applyPreferredInput(plan: Plan) {
        let session = AVAudioSession.sharedInstance()
        let target = preferredInput(for: plan, among: session.availableInputs ?? [])
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
