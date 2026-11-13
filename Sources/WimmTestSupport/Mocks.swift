import Foundation
import WimmInfrastructure
import Combine
import WimmTranscription
import WimmRecording
import WimmDomain

#if ENABLE_LOCAL_AI
import MLX

public func configureMLXForTests() {
    MLX.Device.setDefault(device: .cpu)
}
#else
public func configureMLXForTests() {}
#endif

// MARK: - Mock AudioRecorder

@MainActor
public final class MockAudioRecorder: AudioRecorderProtocol {
    public var isRecording: Bool = false
    private let levelsSubject = PassthroughSubject<[Float], Never>()
    public var audioLevelsPublisher: AnyPublisher<[Float], Never> { levelsSubject.eraseToAnyPublisher() }
    public var duration: TimeInterval = 1
    public private(set) var startCallCount: Int = 0
    public private(set) var stopCallCount: Int = 0
    public private(set) var cancelCallCount: Int = 0
    public var stopDelayNanoseconds: UInt64 = 0
    
    public var mockURL: URL?
    public var shouldFail: Bool = false
    public var mockFileByteCount: Int = 4096
    
    public init() {}
    
    public func startRecording() async throws -> URL {
        if shouldFail { throw NSError(domain: "test", code: 1) }
        startCallCount += 1
        isRecording = true
        let url = mockURL ?? URL(fileURLWithPath: "/tmp/mock.m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: mockFileByteCount), attributes: nil)
        return url
    }
    
    public func stopRecording() async throws -> URL {
        stopCallCount += 1
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
        isRecording = false
        return mockURL ?? URL(fileURLWithPath: "/tmp/mock.m4a")
    }
    
    public func cancelRecording() async {
        cancelCallCount += 1
        isRecording = false
    }
    
    public func sendLevels(_ levels: [Float]) {
        levelsSubject.send(levels)
    }
}

// MARK: - Mock TranscriptionService

// Test mock: mutable tracking state is only touched from one test at a time.
public final class MockTranscriptionService: TranscriberProtocol, @unchecked Sendable {
    public enum MockResult {
        case success(String)
        case failure(CoreTranscriptionFailureReason, underlying: Error?)
    }
    
    public var mockResult: MockResult = .success("Mock transcription")
    public var transcribeCallCount = 0
    public var lastTranscribedFile: URL?
    public var lastEngine: EngineID?
    public var lastModel: String?
    public var lastLanguage: String?
    public var simulationDuration: UInt64 = 50_000_000
    
    public init() {}
    
    public func transcribe(
        file: URL,
        engine: EngineID,
        model: String,
        language: String,
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?,
        onPartial: (@Sendable (String, Bool) -> Void)?
    ) async -> TranscriptionResult {
        lastModel = model
        return await transcribe(file: file, engine: engine, language: language, progress: progress, onPartial: onPartial)
    }

    public func transcribe(
        file: URL,
        engine: EngineID,
        language: String,
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?,
        onPartial: (@Sendable (String, Bool) -> Void)?
    ) async -> TranscriptionResult {
        transcribeCallCount += 1
        lastTranscribedFile = file
        lastEngine = engine
        lastLanguage = language
        
        // Simulate progress
        progress?(0.5, 10.0, 5.0)
        onPartial?("Mock partial transcription", false)
        try? await Task.sleep(nanoseconds: simulationDuration)
        progress?(1.0, 0.0, 10.0)
        
        switch mockResult {
        case .success(let text):
            recordRunSuccess(
                file: file,
                provider: "mock",
                model: lastModel ?? engine.rawValue,
                audioDuration: nil,
                startedAt: Date(),
                elapsedSeconds: Double(simulationDuration) / 1_000_000_000,
                transcript: text,
                speechStatus: .speech,
                rawResponse: nil
            )
            onPartial?(text, true)
            return .success(text)
        case .failure(let reason, let underlying):
            switch reason {
            case .network: return .failure(.network, underlying: underlying)
            case .decoding: return .failure(.decoding, underlying: underlying)
            case .empty: return .failure(.empty, underlying: underlying)
            case .cancelled: return .failure(.cancelled, underlying: underlying)
            case .tooLarge: return .failure(.tooLarge, underlying: underlying)
            case .rateLimited: return .failure(.rateLimited, underlying: underlying)
            case .badStatus: return .failure(.badStatus, underlying: underlying)
            case .permissionDenied: return .failure(.permissionDenied, underlying: underlying)
            case .notSupported: return .failure(.notSupported, underlying: underlying)
            case .temporaryUnavailable: return .failure(.temporaryUnavailable, underlying: underlying)
            case .privateMode: return .failure(.privateMode, underlying: underlying)
            case .unknown: return .failure(.unknown, underlying: underlying)                
            }
        }
    }
}

// MARK: - Test File Creation Helpers

public func createTestRecordingFile(in directory: URL, name: String) throws -> URL {
    let recordingsDir = directory.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    
    let fileURL = recordingsDir.appendingPathComponent(name)
    
    // Create minimal valid M4A header (or just empty file for tests)
    let emptyData = Data(repeating: 0, count: 1024)
    try emptyData.write(to: fileURL)
    
    return fileURL
}

// MARK: - Mock Repositories for Refactoring

public actor MockFileRepository: FileRepositoryProtocol {
    public var recordingsToReturn: [URL] = []
    public var assetsToReturn: [URL: FileRepository.FileAssets] = [:]
    public var recordingURLsToReturn: [URL] = []

    public init() {}
    public func setRecordings(_ urls: [URL]) {
        self.recordingsToReturn = urls
    }
    public func setRecordingURLs(_ urls: [URL]) {
        self.recordingURLsToReturn = urls
    }
    
    public func recordings(order: FileRepository.Order, limit: Int?) -> [URL] {
        return recordingsToReturn
    }
    public func assets(for file: URL) -> FileRepository.FileAssets {
        return assetsToReturn[file] ?? FileRepository.FileAssets(screenshotURL: nil, metadataURL: nil)
    }
    public func deleteRecordingAssets(at file: URL) async {
        // Mock impl
    }
    public func recordingURLs(for noteIds: [String]) async -> [URL] {
        return recordingURLsToReturn
    }
    public func invalidateCache() async {}
}

public actor MockMetadataRepository: @preconcurrency MetadataRepositoryProtocol {
    public var metadataToReturn: [URL: [String: Any]] = [:]
    public var transcriptionInfoToReturn: [URL: MetadataRepository.TranscriptionInfo] = [:]
    public var existingNoteCardToReturn: [URL: NoteCard] = [:]

    public init() {}
    public func transcriptionInfo(for file: URL) -> MetadataRepository.TranscriptionInfo {
        return transcriptionInfoToReturn[file] ?? MetadataRepository.TranscriptionInfo(provider: nil, model: nil, hasRaw: false)
    }
    public func metadata(for file: URL) -> sending [String: Any] {
        nonisolated(unsafe) let result = metadataToReturn[file] ?? [:]
        return result
    }
    public func metadataAndNoteCard(for file: URL) -> sending ([String: Any], NoteCard?) {
        nonisolated(unsafe) let meta = metadataToReturn[file] ?? [:]
        let card = existingNoteCardToReturn[file]
        return (meta, card)
    }
    public func existingNoteCard(for file: URL) -> NoteCard? {
        return existingNoteCardToReturn[file]
    }
    public func setNoteCard(for file: URL, card: NoteCard) {
        existingNoteCardToReturn[file] = card
    }
    public func upsertMetadata(for file: URL, updates: [String: Any]) {
        var current = metadataToReturn[file] ?? [:]
        for (k, v) in updates { current[k] = v }
        metadataToReturn[file] = current
    }
    public func upsertNoteCard(for file: URL, card: NoteCard, lang: String?) async {}
    public func naiveNoteCard(for file: URL, transcript: String) async -> NoteCard? { return nil }
    public func noteCardHasContent(_ card: NoteCard) async -> Bool { return true }
    #if SWIFTDATA_ENABLED && canImport(SwiftData) && !SPM_TESTS
    public func updateNoteMetaEntity(noteId: String, update: @escaping @Sendable (NoteMetaEntity) -> Void) async {}
    #endif
}

public actor MockTranscriptRepository: TranscriptRepositoryProtocol {
    public var textsToReturn: [URL: String] = [:]
    public var localTextsToReturn: [URL: String] = [:]
    public var recordedFailures: [URL: String] = [:]
    
    public init() {}
    public func textOfRecord(for file: URL) -> String? {
        return textsToReturn[file]
    }
    public func transcriptText(for file: URL) -> String? {
        return textsToReturn[file]
    }
    public func localTranscriptText(for file: URL) -> String? {
        return localTextsToReturn[file]
    }
    public func updateTranscriptText(text: String, duration: Double, to file: URL) async throws {
        textsToReturn[file] = text
    }
    public func writeFailurePlaceholder(duration: Double, file: URL, reasonLabel: String?, baseMessage: String) async {
        textsToReturn[file] = "\(baseMessage) (\(reasonLabel ?? "unknown"))"
    }
    public func recordTranscriptionFailure(for file: URL, reason: CoreTranscriptionFailureReason, underlying: Error?) async -> String {
        let msg = "Failure: \(reason)"
        recordedFailures[file] = msg
        return msg
    }
}

public actor MockAttachmentRepository: AttachmentRepositoryProtocol {
    public var attachmentsToReturn: [URL: [NoteAttachment]] = [:]
    public var savedOCRs: [(file: URL, text: String, provider: String, model: String, start: Date)] = []
    
    public init() {}
    public func attachments(for file: URL) -> [NoteAttachment] {
        return attachmentsToReturn[file] ?? []
    }
    public func saveOCR(for file: URL, text: String, provider: String, model: String, startedAt: Date) {
        savedOCRs.append((file, text, provider, model, startedAt))
    }
    public func appendAttachments(for file: URL, attachments: [NoteAttachment]) async {
        var current = attachmentsToReturn[file] ?? []
        current.append(contentsOf: attachments)
        attachmentsToReturn[file] = current
    }
    public func upsertAttachments(for file: URL, attachments: [NoteAttachment]) async {
        // Mock overwrite or append logic
        attachmentsToReturn[file] = attachments
    }
    public func findParentSessionFile(for attachmentFile: URL) async -> URL? {
        return nil
    }
}

public actor MockTrashRepository: TrashRepositoryProtocol {
    public var trashedFiles: [URL] = []
    public var restoredFiles: [URL] = []
    
    public init() {}
    public func moveToTrash(file: URL) -> URL? {
        trashedFiles.append(file)
        return file
    }
    public func restoreFromTrash(file: URL) -> URL? {
        restoredFiles.append(file)
        return file
    }
    public func permanentlyDelete(file: URL) {}
    public func emptyTrash() {}
    public func listTrash(order: FileRepository.Order) -> [URL] { return [] }
}
