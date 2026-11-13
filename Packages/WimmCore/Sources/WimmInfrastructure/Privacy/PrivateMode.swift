import Foundation

/// Private mode: note text reaches cloud models only pseudonymized, and paths
/// that cannot be masked (cloud audio, cloud OCR) refuse. Off by default.
///
/// Enforcement has two layers. `LLMJSONClient` masks and marks its own request
/// with `withPseudonymizedEgress`; `LLMTransport` refuses to build any cloud
/// request that is not marked. So a new caller that skips masking fails
/// closed instead of leaking.
public enum PrivateMode {
    /// `WIMM_PRIVATE_MODE=1|0` overrides the stored setting (tests, CLI runs).
    public static var isEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["WIMM_PRIVATE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            return raw == "1" || raw == "true" || raw == "yes"
        }
        return SharedUserDefaults.store.bool(forKey: DefaultsKey.privateMode)
    }

    public enum Egress: Sendable { case unmarked, pseudonymized, noUserContent }

    @TaskLocal public static var egress: Egress = .unmarked

    /// Marks requests built inside `operation` as already masked.
    public static func withPseudonymizedEgress<T>(
        isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T
    ) async rethrows -> T {
        try await $egress.withValue(.pseudonymized, operation: operation, isolation: isolation)
    }

    /// For requests that carry no note content at all (an API-key check).
    public static func withoutUserContent<T>(
        isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T
    ) async rethrows -> T {
        try await $egress.withValue(.noUserContent, operation: operation, isolation: isolation)
    }

    /// Called by `LLMTransport` before it builds a cloud request.
    public static func checkCloudEgress(provider: String) throws {
        guard isEnabled, egress == .unmarked else { return }
        throw PseudonymizationError.cloudRequestRefused("an unmasked \(provider) request")
    }

    /// True for the refusal above, so UI can say "private mode" instead of a generic failure.
    public static func isRefusal(_ error: Error?) -> Bool {
        guard let error = error as? PseudonymizationError, case .cloudRequestRefused = error else { return false }
        return true
    }

    /// Called by the cloud audio adapters, which cannot be masked.
    public static func refuseCloudAudio(provider: String) throws {
        guard isEnabled else { return }
        throw PseudonymizationError.cloudRequestRefused("audio to \(provider)")
    }
}
