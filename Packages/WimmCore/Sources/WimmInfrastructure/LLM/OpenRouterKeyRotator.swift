import Foundation

// Actor responsible for rotating OpenRouter API keys across retries.
public actor OpenRouterKeyRotator {
    public static let shared = OpenRouterKeyRotator()
    private var keys: [String]

    public init() {
        self.keys = []
        // Avoid touching Keychain during app launch.
        // Keys are loaded lazily on first real usage or explicit reload.
    }

    public func reload() {
        let parts = loadAPIKeys(
            envMultiKey: "OPENROUTER_API_KEYS",
            envSingleKey: "OPENROUTER_API_KEY",
            udMultiKey: "OPENROUTER_API_KEYS",
            udSingleKey: "OPENROUTER_API_KEY",
            placeholder: "REPLACE_WITH_OPENROUTER_KEY",
            minLength: 16,
            dropContainsLowercased: ["replace_with_openrouter_key"]
        )
        self.keys = parts
    }

    public func currentKey() -> String {
        allKeys().first ?? ""
    }

    public func allKeys() -> [String] {
        if keys.isEmpty {
            self.keys = loadAPIKeys(
                envMultiKey: "OPENROUTER_API_KEYS",
                envSingleKey: "OPENROUTER_API_KEY",
                udMultiKey: "OPENROUTER_API_KEYS",
                udSingleKey: "OPENROUTER_API_KEY",
                placeholder: "REPLACE_WITH_OPENROUTER_KEY",
                minLength: 16,
                dropContainsLowercased: ["replace_with_openrouter_key"]
            )
        }
        return keys
    }

    public func count() -> Int {
        allKeys().count
    }
}
