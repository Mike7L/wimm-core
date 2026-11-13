import Foundation

// Actor responsible for rotating Gemini API keys across retries.
public actor APIKeyRotator {
    public static let shared = APIKeyRotator()
    private var keys: [String]

    public init() {
        self.keys = []
        // Avoid touching Keychain during app launch.
        // Keys are loaded lazily on first real usage or explicit reload.
    }

    public func currentKey() -> String {
        allKeys().first ?? ""
    }

    public func reload() {
        self.keys = loadKeys()
    }

    public func allKeys() -> [String] {
        if keys.isEmpty {
            self.keys = loadKeys()
        }
        return keys
    }

    private func loadKeys() -> [String] {
        return loadAPIKeys(
            envMultiKey: "GEMINI_API_KEYS",
            envSingleKey: "GEMINI_API_KEY",
            udMultiKey: "GEMINI_API_KEYS",
            udSingleKey: "GEMINI_API_KEY",
            placeholder: "REPLACE_WITH_YOUR_KEY",
            minLength: 20,
            dropContainsLowercased: ["replace_with_your_key"]
        )
    }

    public func count() -> Int {
        allKeys().count
    }

    /// Removes a key from the current process after the provider explicitly
    /// rejects it. The configured value is left untouched, so Settings remains
    /// the source of truth while long-running jobs stop retrying a dead key.
    public func quarantine(_ key: String) {
        _ = allKeys()
        keys.removeAll { $0 == key }
    }
}
