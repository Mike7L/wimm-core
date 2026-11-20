import Foundation

/// An audio input device discovered on the host (macOS CoreAudio).
public struct AudioInputOption: Equatable, Hashable, Identifiable, Sendable {
    public let uid: String
    public let name: String
    public let transport: String

    public init(uid: String, name: String, transport: String) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    public var id: String { uid }
    public var isBuiltIn: Bool { transport == "builtIn" }
    public var isHeadset: Bool {
        transport == "bluetooth" || name.localizedCaseInsensitiveContains("airpods")
    }
}

/// User preference for which input device Studio capture binds to.
public enum AudioInputPreference: Equatable, Hashable, Sendable {
    case systemDefault
    case builtInOnly
    case device(uid: String)

    public static let defaultsKey = "WimmStudio.audioInputPreference"

    public var rawValue: String {
        switch self {
        case .systemDefault: "systemDefault"
        case .builtInOnly: "builtInOnly"
        case .device(let uid): "device:\(uid)"
        }
    }

    public init(rawValue: String) {
        if rawValue == "builtInOnly" {
            self = .builtInOnly
        } else if rawValue.hasPrefix("device:") {
            let uid = String(rawValue.dropFirst("device:".count))
            self = uid.isEmpty ? .systemDefault : .device(uid: uid)
        } else {
            self = .systemDefault
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> AudioInputPreference {
        guard let raw = defaults.string(forKey: defaultsKey) else { return .systemDefault }
        return AudioInputPreference(rawValue: raw)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Pure routing decisions over discovered input devices and the user's preference.
public enum AudioInputRouting {
    public static func resolve(
        preference: AudioInputPreference,
        available: [AudioInputOption],
        systemDefaultUID: String?
    ) -> AudioInputOption? {
        let fallback = systemDefaultUID.flatMap { uid in available.first { $0.uid == uid } } ?? available.first
        switch preference {
        case .systemDefault:
            return fallback
        case .builtInOnly:
            return available.first(where: \.isBuiltIn) ?? fallback
        case .device(let uid):
            return available.first { $0.uid == uid } ?? fallback
        }
    }

    /// UID to explicitly bind on CoreAudio's AUHAL input unit, or `nil` when following system default.
    public static func boundDeviceUID(
        preference: AudioInputPreference,
        available: [AudioInputOption],
        systemDefaultUID: String?
    ) -> String? {
        _ = systemDefaultUID
        switch preference {
        case .systemDefault:
            return nil
        case .builtInOnly:
            return available.first(where: \.isBuiltIn)?.uid
        case .device(let uid):
            return available.first { $0.uid == uid }?.uid
        }
    }

    public static func toggleTarget(
        current: AudioInputOption?,
        available: [AudioInputOption]
    ) -> AudioInputOption? {
        guard available.count >= 2 else { return nil }
        if current?.isBuiltIn == true {
            return available.first(where: \.isHeadset)
                ?? available.first { !$0.isBuiltIn && $0.uid != current?.uid }
        }
        return available.first(where: \.isBuiltIn)
            ?? available.first { $0.uid != current?.uid }
    }

    public static func toggledPreference(
        current: AudioInputOption?,
        available: [AudioInputOption]
    ) -> AudioInputPreference? {
        guard let target = toggleTarget(current: current, available: available) else { return nil }
        return target.isBuiltIn ? .builtInOnly : .device(uid: target.uid)
    }
}
