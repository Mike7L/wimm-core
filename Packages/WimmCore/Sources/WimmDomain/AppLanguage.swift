import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case english
    case russian
    case german

    public static let defaultsKey = "appLanguage"

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .russian:
            return Locale(identifier: "ru")
        case .german:
            return Locale(identifier: "de")
        }
    }

    public var title: String {
        switch self {
        case .system:
            return "System"
        case .english:
            return "English"
        case .russian:
            return "Русский"
        case .german:
            return "Deutsch"
        }
    }

    public init(storedValue: String?) {
        guard let storedValue, let parsed = AppLanguage(rawValue: storedValue) else {
            self = .system
            return
        }
        self = parsed
    }
}
