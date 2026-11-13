import Foundation
import Security

public enum APIKeySecureStore {
    private static let service = "app.wimm.keys"

    public static func isRunningTests() -> Bool {
        if RuntimeFlags.isTestModeEnabled { return true }
        if ProcessInfo.processInfo.environment["WIMM_TEST_MODE"] != nil { return true }
        if ProcessInfo.processInfo.environment["WIMM_DISABLE_KEYCHAIN"] == "1" { return true }
        if let suite = ProcessInfo.processInfo.environment["WIMM_DEFAULTS_SUITE"],
           !suite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // Fallback for XCTest runs where WIMM_TEST_MODE was not injected.
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func account(for key: String) -> String {
        "userdefaults:\(key)"
    }

    public static func read(_ key: String) -> String? {
        if isRunningTests() { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func write(_ value: String, for key: String) {
        if isRunningTests() { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            delete(key)
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: key)
        ]

        let attrs: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var create = baseQuery
        create[kSecValueData as String] = data
        SecItemAdd(create as CFDictionary, nil)
    }

    public static func delete(_ key: String) {
        if isRunningTests() { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: key)
        ]
        SecItemDelete(query as CFDictionary)
    }

}
