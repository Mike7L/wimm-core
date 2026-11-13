import Foundation
import WimmDomain

// MARK: - Shared test doubles for WimmCoreTests
//
// All conformances use `final class` + `@unchecked Sendable` so that Swift 6's
// actor-isolation checker does not object to nonisolated protocol requirements.
// Mutable state is protected via a `lock` where needed.

// MARK: StubTranscriber

/// Returns fixed text for every transcribe/stop call.
final class StubTranscriber: TranscriptionPort, @unchecked Sendable {
    private let fixedText: String

    init(fixedText: String = "transcribed text") {
        self.fixedText = fixedText
    }

    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stopCapture() async throws -> (audioData: Data, finalText: String) {
        (Data(), fixedText)
    }

    func transcribeFile(at fileURL: URL) async throws -> String {
        fixedText
    }
}

// MARK: StubAnalysis

/// Returns a fixed AnalysisCard for every analyze call.
final class StubAnalysis: AnalysisPort, @unchecked Sendable {
    private let fixedCard: AnalysisCard

    init(card: AnalysisCard? = nil) {
        self.fixedCard = card ?? AnalysisCard(
            title: "Stub Title",
            summary: "Stub summary",
            tags: [],
            projects: []
        )
    }

    func analyze(text: String) async throws -> AnalysisCard { fixedCard }
}

// MARK: FailingAnalysis

/// Throws an NSError with the given domain, code, and message on every analyze call.
final class FailingAnalysis: AnalysisPort, @unchecked Sendable {
    private let domain: String
    private let code: Int
    private let message: String

    init(domain: String = "Test", code: Int = 1, message: String? = nil) {
        self.domain = domain
        self.code = code
        self.message = message ?? "error \(code)"
    }

    func analyze(text: String) async throws -> AnalysisCard {
        throw NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

}

// MARK: FlakyAnalysis

/// Fails the first N calls, then succeeds.
final class FlakyAnalysis: AnalysisPort, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int
    private var _callCount: Int = 0
    private let errorFactory: @Sendable () -> NSError

    var callCount: Int {
        lock.withLock { _callCount }
    }

    init(failuresBeforeSuccess: Int, errorFactory: @escaping @Sendable () -> NSError) {
        self.failuresRemaining = failuresBeforeSuccess
        self.errorFactory = errorFactory
    }

    func analyze(text: String) async throws -> AnalysisCard {
        let (shouldFail, error): (Bool, NSError?) = lock.withLock {
            _callCount += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                return (true, errorFactory())
            }
            return (false, nil)
        }
        if shouldFail, let error { throw error }
        return AnalysisCard(title: "ok", summary: text, tags: [], projects: [])
    }

}
