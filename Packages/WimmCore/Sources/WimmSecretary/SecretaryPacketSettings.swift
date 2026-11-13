import Foundation

/// UTF-8 source budget; document context is separate. KB uses decimal bytes.
public enum SecretaryPacketSettings {
    public static let defaultsKey = "Secretary.packetSourceKB"
    public static let defaultKB = 512
    public static let minimumKB = 64
    public static let maximumKB = 1024
    public static let stepKB = 64

    public static func normalize(_ value: Int) -> Int {
        let bounded = min(maximumKB, max(minimumKB, value))
        return Int((Double(bounded) / Double(stepKB)).rounded()) * stepKB
    }

    public static func preferredKB(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: defaultsKey) as? NSNumber,
              value.doubleValue.isFinite else { return defaultKB }
        return normalize(Int(min(Double(maximumKB), max(Double(minimumKB), value.doubleValue))))
    }
}
