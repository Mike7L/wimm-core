import Foundation

// Ordered set preserving insertion order, for simple duplicate removal without importing extra libs.
struct LinkedHashSet<Element: Hashable>: Sequence {
    private var seen = Set<Element>()
    private var order: [Element] = []
    init(_ elements: [Element]) {
        for e in elements { if seen.insert(e).inserted { order.append(e) } }
    }
    func makeIterator() -> IndexingIterator<[Element]> { order.makeIterator() }
}

/// Load and sanitize API keys from environment and UserDefaults.
/// - Parameters:
///   - envMultiKey: Environment variable containing multiple keys.
///   - envSingleKey: Environment variable containing a single key.
///   - udMultiKey: UserDefaults key for multiple keys.
///   - udSingleKey: UserDefaults key for single key.
///   - placeholder: Placeholder to use when nothing valid is found.
///   - minLength: Minimum acceptable key length.
///   - dropContainsLowercased: Substrings (lowercased) that, if present, cause a candidate to be dropped.
/// - Returns: A non-empty array of keys, de-duplicated and sanitized. If nothing valid is found, returns [placeholder].
func loadAPIKeys(envMultiKey: String,
                 envSingleKey: String,
                 udMultiKey: String,
                 udSingleKey: String,
                 placeholder: String,
                 minLength: Int = 16,
                 dropContainsLowercased: [String] = []) -> [String] {
    let env = ProcessInfo.processInfo.environment
    let ud = UserDefaults.standard
    
    var raw: String?
    
    // 1. Dedicated test key from environment (highest priority for developers/CI)
    if let val = env["TEST_" + envMultiKey], !val.isEmpty {
        raw = val
    } else if let val = env["TEST_" + envSingleKey], !val.isEmpty {
        raw = val
    // 2. Regular environment values (.env / CLI / launchctl)
    } else if let val = env[envMultiKey], !val.isEmpty {
        raw = val
    } else if let val = env[envSingleKey], !val.isEmpty {
        raw = val
    // 3. Normal key from Settings UI (UserDefaults / @AppStorage)
    } else if let val = ud.string(forKey: udMultiKey), !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        raw = val
    } else if let val = ud.string(forKey: udSingleKey), !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        raw = val
    // 3b. The macOS app's Settings, read from another process (wimm-cli).
    } else if let val = appSettingsValue(keys: [udMultiKey, udSingleKey]) {
        raw = val
    // 4. Fallback to SecureStore (Keychain)
    } else if let val = APIKeySecureStore.read(udMultiKey), !val.isEmpty {
        raw = val
    } else if let val = APIKeySecureStore.read(udSingleKey), !val.isEmpty {
        raw = val
    } else if let val = bundledInfoValue(
        keys: [envMultiKey, envSingleKey, udMultiKey, udSingleKey]
    ) {
        raw = val
    }
    
    let partsStr = raw ?? placeholder
    let delimiters = CharacterSet(charactersIn: ",; \n\t")
    var parts = partsStr.components(separatedBy: delimiters)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if !dropContainsLowercased.isEmpty || minLength > 0 {
        parts = parts.filter { s in
            if s.count < minLength { return false }
            let lower = s.lowercased()
            for bad in dropContainsLowercased { if lower.contains(bad) { return false } }
            return true
        }
    }

    parts = Array(LinkedHashSet(parts))
    return parts.isEmpty ? [placeholder] : parts
}

/// Defaults domain the macOS app's Settings write API keys into
/// (`@AppStorage` → the app's `UserDefaults.standard`). Overridable with
/// `WIMM_APP_DEFAULTS_DOMAIN`.
public let appSettingsDefaultsDomain = "com.micha.wimm.macos"

/// A key from the macOS app's Settings when the current process is *not* the
/// app. Without this `wimm-cli` only saw its own empty defaults domain and fell
/// through to a Keychain copy the Settings field never updates — on 2026-10-24
/// that copy held five revoked keys while the app transcribed fine. Never read
/// under tests or an isolated instance (same rule as `APIKeySecureStore`).
private func appSettingsValue(keys: [String]) -> String? {
    if APIKeySecureStore.isRunningTests() { return nil }
    let domain = ProcessInfo.processInfo.environment["WIMM_APP_DEFAULTS_DOMAIN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty ?? appSettingsDefaultsDomain
    guard Bundle.main.bundleIdentifier != domain,
          let defaults = UserDefaults(suiteName: domain) else { return nil }
    for key in keys {
        if let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
    }
    return nil
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private func bundledInfoValue(keys: [String]) -> String? {
    guard let info = Bundle.main.infoDictionary else { return nil }
    for key in keys {
        if let value = info[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }
    return nil
}
