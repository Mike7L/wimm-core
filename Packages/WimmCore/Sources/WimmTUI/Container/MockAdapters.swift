import Foundation
import WimmDomain

// MARK: - Test / Preview Adapters

final class MockTranscriptionAdapter: TranscriptionPort {
    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continuation.yield("Hello...")
                try? await Task.sleep(nanoseconds: 500_000_000)
                continuation.yield("Hello world...")
                continuation.finish()
            }
        }
    }

    func stopCapture() async throws -> (audioData: Data, finalText: String) {
        (Data(), "Hello world recorded")
    }

    func transcribeFile(at fileURL: URL) async throws -> String {
        "Mock transcription for \(fileURL.lastPathComponent)"
    }
}

final class MockAnalysisAdapter: AnalysisPort {
    func analyze(text: String) async throws -> AnalysisCard {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return AnalysisCard(
            title: "Mock Title",
            summary: "Arguments parsed: \(text)",
            tags: ["mock", "test"],
            projects: []
        )
    }


}

final class MockQuestionAnsweringAdapter: QuestionAnsweringPort {
    func answer(
        question: String,
        note: CapturedNote,
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        "Mock answer to '\(question)' for note '\(note.id)'"
    }
}

final class MockNoteCollectionAnsweringAdapter: NoteCollectionAnsweringPort {
    func answer(
        question: String,
        notes: [CapturedNote],
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        "Mock answer to '\(question)' for \(notes.count) notes"
    }
}
