import Foundation
import WimmDomain
import WimmInfrastructure

typealias NoteCollectionAnalyzer = @Sendable ([String], String, String?, String?) async throws -> NoteCollectionAnswer
typealias ChatSender = @Sendable (String, [String]?, String) async -> Void

// MARK: - WimmGateway

@MainActor
protocol WimmHUDGatewayProtocol: AnyObject {
    func makeHUDController(autoProcessAfterRecord: Bool) async throws -> HUDController
    func performHUDExternalAction(_ action: HUDExternalAction) async throws -> String
}

extension WimmHUDGatewayProtocol {
    func makeHUDController() async throws -> HUDController {
        try await makeHUDController(autoProcessAfterRecord: true)
    }
}

/// Singleton facade that exposes WIMM use cases to app GUIs.
/// Shares the same storage root as Wimm (`~/Library/Application Support/Wimm`).
final class WimmGateway: @unchecked Sendable, WimmHUDGatewayProtocol {

    static let shared = WimmGateway()

    let storageRoot: URL
    let queueSupervisor: QueueSupervisor
    let analyzeNoteCollectionUseCase: AnalyzeNoteCollectionUseCase

    private let storage: StoragePort
    private let listNotes: ListNotesUseCase
    private let queueStatus: GetQueueStatusUseCase

    private init() {
        let root = Self.resolveStorageRoot()
        self.storageRoot = root
        let storage = FileSystemAdapter(rootDirectory: root)
        let analysis = Self.makeAnalysis()
        let noteCollectionAnswering = Self.makeNoteCollectionAnswering()
        self.storage = storage
        self.listNotes = ListNotesUseCase(storage: storage)
        self.queueStatus = GetQueueStatusUseCase(storage: storage)
        self.queueSupervisor = QueueSupervisor(storage: storage, analysis: analysis)
        self.analyzeNoteCollectionUseCase = AnalyzeNoteCollectionUseCase(storage: storage, answering: noteCollectionAnswering)
    }

    func makeHUDController(autoProcessAfterRecord: Bool = true) async throws -> HUDController {
        let dependencies = HUDController.Dependencies(
            rootPath: storageRoot.path,
            storage: storage,
            transcriber: Self.makeTranscriber(),
            queueSupervisor: queueSupervisor,
            loadSnapshot: {
                Self.lightweightHUDSnapshot()
            }
        )
        return try await HUDController.bootstrap(
            dependencies: dependencies,
            autoProcessAfterRecord: autoProcessAfterRecord
        )
    }

    func performHUDExternalAction(_ action: HUDExternalAction) async throws -> String {
        switch action {
        case .processQueue:
            let processed = try await queueSupervisor.processQueue()
            return "Processed \(processed) note(s)."
        case .exportNotes:
            return try await exportLatestNotes(limit: 50)
        case .showStats:
            return try await renderStats()
        case .listRecent:
            return try await renderRecentNotes(limit: 10)
        }
    }

    func analyzeNoteCollection(
        noteIDs: [String],
        rawQuestion: String,
        role: String?,
        outputLanguage: String?
    ) async throws -> NoteCollectionAnswer {
        let uuids = try noteIDs.map { noteID in
            guard let uuid = UUID(uuidString: noteID) else {
                throw StorageError.noteNotFound(noteID)
            }
            return uuid
        }
        return try await analyzeNoteCollectionUseCase.execute(
            noteIDs: uuids,
            rawQuestion: rawQuestion,
            role: role,
            outputLanguage: outputLanguage
        )
    }

    private static func resolveStorageRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["WIMM_ROOT_DIR"]?.trimmingCharacters(in: .whitespaces), !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        if let dir = env["WIMM_BASE_DIR"]?.trimmingCharacters(in: .whitespaces), !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
#if os(iOS)
        if let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.micha.wimm") {
            return groupDir.appendingPathComponent("Wimm", isDirectory: true)
        }
#endif
        // Same default as the note store — including its refusal to hand a
        // test process the real library.
        return StoragePaths.baseDirectory()
    }

    private static func makeAnalysis() -> any AnalysisPort {
        let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "GEMINI_API_KEY")
            ?? ""
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NoOpAnalysisAdapter()
        }
        return RetryDecorator(decoratee: GeminiAdapter(apiKey: apiKey))
    }

    private static func makeNoteCollectionAnswering() -> any NoteCollectionAnsweringPort {
        let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "GEMINI_API_KEY")
            ?? ""
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NoOpNoteCollectionAnsweringAdapter()
        }
        return GeminiNoteCollectionAnsweringAdapter(apiKey: apiKey)
    }

    private static func makeTranscriber() -> any TranscriptionPort {
        let env = ProcessInfo.processInfo.environment
        let engine = TranscriptionEngine.fromEnvironment(env)
        return TranscriptionAdapterFactory.make(
            engine: engine,
            environment: env,
            mockFactory: AppMockTranscriptionAdapter()
        )
    }

    nonisolated private static func lightweightHUDSnapshot() -> HUDSnapshot {
        HUDSnapshot(
            generatedAt: Date(),
            total: 0,
            pending: 0,
            completed: 0,
            failedRetryable: 0,
            failedNonRetryable: 0,
            recent: []
        )
    }

    private func renderStats() async throws -> String {
        let notes = try await listNotes.execute()
        var completed = 0
        var pending = 0
        var failed = 0

        for note in notes {
            switch note.status {
            case .completed:
                completed += 1
            case .pendingAnalysis:
                pending += 1
            case .failed:
                failed += 1
            }
        }

        return [
            "WIMM Statistics",
            "Root: \(storageRoot.path)",
            "Total: \(notes.count)",
            "Completed: \(completed)",
            "Pending: \(pending)",
            "Failed: \(failed)"
        ].joined(separator: "\n")
    }

    private func renderRecentNotes(limit: Int) async throws -> String {
        let notes = try await listNotes.execute()
        let recent = hudPreferredRecentNotes(from: notes, limit: limit)

        guard !recent.isEmpty else {
            return "Recent notes\n(no notes)"
        }

        var lines = ["Recent notes"]
        for note in recent {
            lines.append("[\(note.shortID)] \(note.createdAt) \(hudStatusLabel(for: note.status)) \(hudDisplayTitle(for: note))")
        }
        return lines.joined(separator: "\n")
    }

    private func exportLatestNotes(limit: Int) async throws -> String {
        let notes = try await listNotes.execute()
        let limited = Array(notes.prefix(max(0, limit)))
        let timestamp = ISO8601.now.replacingOccurrences(of: ":", with: "-")
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm_export_\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var lines: [String] = ["# WIMM Export", ""]
        for note in limited {
            lines.append("## \(hudDisplayTitle(for: note))")
            lines.append("- Date: \(note.createdAt)")
            lines.append("- Status: \(note.status)")
            if let tags = note.card?.tags, !tags.isEmpty {
                lines.append("- Tags: \(tags.joined(separator: ", "))")
            }
            if !note.text.isEmpty {
                lines.append("")
                lines.append(note.text)
            }
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        let fileURL = outDir.appendingPathComponent("notes.md")
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return "Exported \(limited.count) note(s) to:\n\(fileURL.path)"
    }

}

private final class AppMockTranscriptionAdapter: TranscriptionPort, @unchecked Sendable {
    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield("Hello...")
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

private final class NoOpAnalysisAdapter: AnalysisPort, @unchecked Sendable {
    func analyze(text: String) async throws -> WimmDomain.AnalysisCard {
        throw WimmGatewayError.noApiKey
    }
}

private struct NoOpNoteCollectionAnsweringAdapter: NoteCollectionAnsweringPort, Sendable {
    func answer(
        question: String,
        notes: [WimmDomain.CapturedNote],
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        _ = question
        _ = notes
        _ = role
        _ = outputLanguage
        throw WimmGatewayError.noApiKey
    }
}

private enum WimmGatewayError: LocalizedError {
    case noApiKey
    var errorDescription: String? {
        "Gemini API key not configured. Please add it in Settings."
    }
}
