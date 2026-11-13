import Foundation
import WimmDomain
import WimmInfrastructure

// MARK: - Composition Root

struct AppContainer: Sendable {
    let storage: StoragePort
    let analysis: AnalysisPort
    let transcriber: TranscriptionPort
    let queueSupervisor: QueueSupervisor
    let listNotes: ListNotesUseCase
    let readNote: ReadNoteUseCase
    let searchNotes: SearchNotesUseCase
    let processFile: ProcessFileUseCase
    let capture: CaptureUseCase
    let queueStatus: GetQueueStatusUseCase
    let failedReport: GenerateFailedReportUseCase
    let analyzeNoteCollection: AnalyzeNoteCollectionUseCase
    let askNoteQuestion: AskNoteQuestionUseCase
    /// Resolved storage root directory (useful for commands that need direct file access).
    let storageRoot: URL

    init() {
        let root = Self.resolveStorageRoot()
        self.storageRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("WIMM storage root: \(root.path)")

        self.storage          = FileSystemAdapter(rootDirectory: root)
        self.transcriber      = Self.makeTranscriber()
        self.analysis         = Self.makeAnalysis()
        self.queueSupervisor  = QueueSupervisor(storage: storage, analysis: analysis)
        self.listNotes        = ListNotesUseCase(storage: storage)
        self.readNote         = ReadNoteUseCase(storage: storage)
        self.searchNotes      = SearchNotesUseCase(storage: storage)
        self.processFile      = ProcessFileUseCase(storage: storage, transcription: transcriber, analysis: analysis)
        self.capture          = CaptureUseCase(transcription: transcriber, analysis: analysis, storage: storage)
        self.queueStatus      = GetQueueStatusUseCase(storage: storage)
        self.failedReport     = GenerateFailedReportUseCase(storage: storage)

        let answeringPort     = Self.makeQuestionAnswering()
        let collectionPort    = Self.makeNoteCollectionAnswering()
        self.askNoteQuestion  = AskNoteQuestionUseCase(storage: storage, answering: answeringPort)
        self.analyzeNoteCollection = AnalyzeNoteCollectionUseCase(storage: storage, answering: collectionPort)
    }

    // MARK: - Adapter factories

    private static func makeTranscriber() -> TranscriptionPort {
        let env = ProcessInfo.processInfo.environment
        let engine = TranscriptionEngine.fromEnvironment(env)
        return TranscriptionAdapterFactory.make(
            engine: engine,
            environment: env,
            mockFactory: MockTranscriptionAdapter()
        )
    }

    private static func makeAnalysis() -> AnalysisPort {
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
            print("No GEMINI_API_KEY found. Using Mock Analysis.")
            return MockAnalysisAdapter()
        }
        print("Using REAL Gemini Adapter.")
        let gemini = GeminiAdapter(apiKey: apiKey)
        let retrying = RetryDecorator(decoratee: gemini)
        return TelemetryDecorator(decoratee: retrying) { print("[Telemetry] \($0)") }
    }

    private static func makeQuestionAnswering() -> QuestionAnsweringPort {
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
            return MockQuestionAnsweringAdapter()
        }
        return GeminiQuestionAnsweringAdapter(apiKey: apiKey)
    }

    private static func makeNoteCollectionAnswering() -> NoteCollectionAnsweringPort {
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
            return MockNoteCollectionAnsweringAdapter()
        }
        return GeminiNoteCollectionAnsweringAdapter(apiKey: apiKey)
    }

    // MARK: - Storage root resolution

    private static func resolveStorageRoot() -> URL {
        let env = ProcessInfo.processInfo.environment

        if let wimmRoot = env["WIMM_ROOT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !wimmRoot.isEmpty {
            return URL(fileURLWithPath: wimmRoot, isDirectory: true).resolvingSymlinksInPath()
        }

        if let wimmBase = env["WIMM_BASE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !wimmBase.isEmpty {
            return URL(fileURLWithPath: wimmBase, isDirectory: true).resolvingSymlinksInPath()
        }

        // Same default as the note store — including its refusal to hand a
        // test process the real library.
        return StoragePaths.baseDirectory()
    }
}
