import Foundation

/// Private mode: nothing reaches a cloud model. Every cloud request refuses;
/// on-device work (Parakeet, Vision OCR, local search) is unaffected. Off by
/// default. There is no masked middle ground: pseudonymization was removed
/// (2026-11-17) because no one used it and it taxed every cloud feature.
///
/// `LLMTransport` checks before it builds any request, so a new caller that
/// goes through it fails closed. Code that bypasses it calls
/// `checkCloudEgress` itself.
public enum PrivateMode {
    /// `WIMM_PRIVATE_MODE=1|0` overrides the stored setting (tests, CLI runs).
    public static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["WIMM_PRIVATE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            return raw == "1" || raw == "true" || raw == "yes"
        }
        return SharedUserDefaults.store.bool(forKey: DefaultsKey.privateMode)
    }

    /// The stored switch (Studio's menu). `WIMM_PRIVATE_MODE` still wins when set.
    /// Written to the shared suite, the one place every reader looks
    /// (Studio, CLI, MCP, the web server).
    public static func setStored(_ enabled: Bool) {
        SharedUserDefaults.store.set(enabled, forKey: DefaultsKey.privateMode)
    }

    /// Called before any cloud request is built.
    public static func checkCloudEgress(provider: String) throws {
        guard isEnabled else { return }
        throw PrivateModeError.cloudRequestRefused("a \(provider) request")
    }

    /// True for the refusal above, so UI can say "private mode" instead of a generic failure.
    public static func isRefusal(_ error: Error?) -> Bool {
        guard let error = error as? PrivateModeError, case .cloudRequestRefused = error else { return false }
        return true
    }

    /// Called by the cloud audio adapters.
    public static func refuseCloudAudio(provider: String) throws {
        guard isEnabled else { return }
        throw PrivateModeError.cloudRequestRefused("audio to \(provider)")
    }
}

public enum PrivateModeError: LocalizedError, Equatable, Sendable {
    case cloudRequestRefused(String)

    public var errorDescription: String? {
        switch self {
        case .cloudRequestRefused(let what):
            return "Private mode: \(what) was not sent to the cloud."
        }
    }
}
