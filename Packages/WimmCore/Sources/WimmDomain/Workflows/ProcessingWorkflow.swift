import Foundation

/// Encapsulates the logic of a single processing pass: analyze a set of notes,
/// persist results, and count successes/failures.
///
/// Extracted from ``QueueSupervisor`` to keep the actor thin and the logic testable.
public struct ProcessingWorkflow: Sendable {
    public typealias ProgressHandler = @Sendable (Int, Int) async -> Void

    /// Upper bound on per-note text fed to analysis. A single huge note (the
    /// Evernote archive has some >400k chars) would otherwise risk a context
    /// overflow. The stored note keeps its full text; only the analysis copy is
    /// truncated.
    public static let maxAnalysisChars = 8_000

    private let storage: StoragePort
    private let analysis: AnalysisPort
    public init(storage: StoragePort, analysis: AnalysisPort) {
        self.storage = storage
        self.analysis = analysis
    }

    /// Process a pre-selected list of notes (already filtered by the caller).
    ///
    /// Each note is analyzed on its own. This used to be one atomic batch call,
    /// which meant a single note the model choked on — a malformed import, a
    /// note that tripped a safety filter — marked every sibling in the pass
    /// `.failed` and threw. A note's outcome is now its own.
    ///
    /// - Parameters:
    ///   - notes: Notes to process in order.
    ///   - onProgress: Called after each attempt with (attempts finished, total),
    ///     so the count reaches `total` whether or not every note succeeded.
    /// - Returns: Number of notes that finished with `.completed` status.
    /// - Throws: The first error seen, but **only if every note failed** — that
    ///   is the shape of a broken run (no API key, rate limit) rather than a
    ///   poison note, and the caller needs it to back off.
    public func run(
        notes: [CapturedNote],
        onProgress: ProgressHandler? = nil
    ) async throws -> Int {
        guard !notes.isEmpty else { return 0 }
        let total = notes.count
        await onProgress?(0, total)

        var processedCount = 0
        var firstError: Error?

        for (index, note) in notes.enumerated() {
            do {
                var analyzed = note
                analyzed.card = try await analysis.analyze(
                    text: Self.clampForAnalysis(note.text))
                analyzed.status = .completed
                try await storage.updateNote(analyzed)
                processedCount += 1
            } catch {
                if firstError == nil { firstError = error }
                var failed = note
                failed.status = .failed(
                    reason: error.localizedDescription,
                    retryable: RetryPolicy.isRetryable(error)
                )
                try? await storage.updateNote(failed)
            }
            await onProgress?(index + 1, total)
        }

        if processedCount == 0, let firstError {
            throw firstError
        }
        return processedCount
    }

    /// Truncates `text` to ``maxAnalysisChars`` on a whitespace boundary, adding
    /// a marker so the model knows the note was clipped.
    static func clampForAnalysis(_ text: String) -> String {
        guard text.count > maxAnalysisChars else { return text }
        let cut = text.index(text.startIndex, offsetBy: maxAnalysisChars)
        var truncated = String(text[..<cut])
        if let lastSpace = truncated.lastIndex(where: { $0 == " " || $0 == "\n" }),
           truncated.distance(from: lastSpace, to: truncated.endIndex) < 200 {
            truncated = String(truncated[..<lastSpace])
        }
        return truncated + "\n\n[…truncated for analysis…]"
    }
}
