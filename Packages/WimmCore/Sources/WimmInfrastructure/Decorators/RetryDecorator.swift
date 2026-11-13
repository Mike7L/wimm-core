import Foundation
import WimmDomain

public final class RetryDecorator: AnalysisPort, Sendable {
    private let decoratee: AnalysisPort
    private let maxAttempts: Int
    private let initialDelayNanoseconds: UInt64

    public init(
        decoratee: AnalysisPort,
        maxAttempts: Int = 3,
        initialDelayNanoseconds: UInt64 = 300_000_000
    ) {
        self.decoratee = decoratee
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
    }

    public func analyze(text: String) async throws -> AnalysisCard {
        try await withRetry {
            try await decoratee.analyze(text: text)
        }
    }


    private func withRetry<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 0
        var delay = initialDelayNanoseconds
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await work()
            } catch {
                lastError = error
                guard RetryPolicy.isRetryable(error), attempt < maxAttempts else {
                    throw error
                }
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 5_000_000_000)
            }
        }

        throw lastError
            ?? NSError(
                domain: "RetryDecorator", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown retry error"])
    }
}
