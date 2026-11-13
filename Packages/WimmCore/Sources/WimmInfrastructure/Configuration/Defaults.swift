import Foundation

/// Read-with-seed accessors over `UserDefaults.standard`.
///
/// Almost every persisted UI preference wants the same thing: return the stored
/// value, and if the key has never been written, write the default once so the
/// key shows up in `defaults read` and in the Settings UI's own inspection.
/// Spelled out inline that is a five-line initializer per property, and it was
/// copied about twenty times into `WimmWindowModel` — with two divergences that
/// only the copies explain: one property used a bare string instead of its
/// `DefaultsKey`, and another skipped the seed entirely.
///
/// `UserDefaults.bool(forKey:)` returns `false` for a missing key, so a
/// default-`true` preference *must* go through the `object(forKey:) == nil`
/// check rather than the plain getter.
public enum Defaults {

    public static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        let store = UserDefaults.standard
        guard store.object(forKey: key) != nil else {
            store.set(defaultValue, forKey: key)
            return defaultValue
        }
        return store.bool(forKey: key)
    }

    public static func double(_ key: String, default defaultValue: Double) -> Double {
        let store = UserDefaults.standard
        guard store.object(forKey: key) != nil else {
            store.set(defaultValue, forKey: key)
            return defaultValue
        }
        return store.double(forKey: key)
    }

    public static func int(_ key: String, default defaultValue: Int) -> Int {
        let store = UserDefaults.standard
        guard store.object(forKey: key) != nil else {
            store.set(defaultValue, forKey: key)
            return defaultValue
        }
        return store.integer(forKey: key)
    }

    public static func string(_ key: String, default defaultValue: String) -> String {
        let store = UserDefaults.standard
        guard let stored = store.string(forKey: key) else {
            store.set(defaultValue, forKey: key)
            return defaultValue
        }
        return stored
    }

    /// A `RawRepresentable` preference (an enum backed by `String`). An
    /// unreadable or no-longer-valid raw value falls back to `defaultValue`
    /// without rewriting the key, so a value written by a newer build survives
    /// a downgrade.
    public static func value<T: RawRepresentable>(
        _ key: String,
        default defaultValue: T
    ) -> T where T.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let parsed = T(rawValue: raw) else {
            return defaultValue
        }
        return parsed
    }

    public static func set(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    public static func set(_ value: Double, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    public static func set(_ value: Int, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    public static func set(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    public static func set<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }
}
