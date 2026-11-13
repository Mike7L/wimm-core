import Foundation

public actor HUDController {
    public struct Dependencies: Sendable {
        public let rootPath: String
        public let storage: StoragePort
        public let transcriber: TranscriptionPort
        public let queueSupervisor: QueueSupervisor
        public let loadSnapshot: @Sendable () async throws -> HUDSnapshot

        public init(
            rootPath: String,
            storage: StoragePort,
            transcriber: TranscriptionPort,
            queueSupervisor: QueueSupervisor,
            loadSnapshot: @escaping @Sendable () async throws -> HUDSnapshot
        ) {
            self.rootPath = rootPath
            self.storage = storage
            self.transcriber = transcriber
            self.queueSupervisor = queueSupervisor
            self.loadSnapshot = loadSnapshot
        }
    }

    private let dependencies: Dependencies
    private var snapshot: HUDSnapshot
    private var autoProcessAfterRecord: Bool
    private var showHelp = false
    private var lastMessage = "Ready."
    private var recordingState: HUDRecordingState?
    private var reviewNote: CapturedNote?
    private var reviewState: HUDReviewState?

    public init(
        dependencies: Dependencies,
        initialSnapshot: HUDSnapshot,
        autoProcessAfterRecord: Bool
    ) {
        self.dependencies = dependencies
        self.snapshot = initialSnapshot
        self.autoProcessAfterRecord = autoProcessAfterRecord
    }

    public static func bootstrap(
        dependencies: Dependencies,
        autoProcessAfterRecord: Bool
    ) async throws -> HUDController {
        let snapshot = try await dependencies.loadSnapshot()
        return HUDController(
            dependencies: dependencies,
            initialSnapshot: snapshot,
            autoProcessAfterRecord: autoProcessAfterRecord
        )
    }

    public func viewState() async -> HUDViewState {
        let liveTranscriptPreview: String?
        if let recordingState {
            liveTranscriptPreview = await recordingState.liveTranscript.preview(maxLength: 140)
        } else {
            liveTranscriptPreview = nil
        }

        return HUDViewState(
            snapshot: snapshot,
            rootPath: dependencies.rootPath,
            autoProcessAfterRecord: autoProcessAfterRecord,
            recordingSince: recordingState?.startedAt,
            liveTranscriptPreview: liveTranscriptPreview,
            reviewState: reviewState,
            showHelp: showHelp,
            lastMessage: lastMessage
        )
    }

    public func dispatch(_ action: HUDAction) async -> HUDControllerEffect {
        switch action {
        case .toggleRecording:
            return await handleToggleRecording()
        case .cancelRecording:
            return await handleCancelRecording()
        case .requestEditLastTranscript:
            return handleRequestEditLastTranscript()
        case .applyTranscriptEdit(let text):
            return await handleApplyTranscriptEdit(text)
        case .deleteLastNote:
            return await handleDeleteLastNote()
        case .toggleHelp:
            showHelp.toggle()
            lastMessage = showHelp ? "Help opened." : "Help closed."
            return .none
        case .refresh:
            await refreshSnapshot(successMessage: "Dashboard refreshed.", failurePrefix: "Refresh failed")
            return .none
        case .toggleAutoProcess:
            autoProcessAfterRecord.toggle()
            lastMessage = "Auto-process after record: \(autoProcessAfterRecord ? "on" : "off")."
            return .none
        case .processQueue:
            return .runExternalAction(.processQueue)
        case .exportNotes:
            return .runExternalAction(.exportNotes)
        case .showStats:
            return .runExternalAction(.showStats)
        case .listRecent:
            return .runExternalAction(.listRecent)
        case .close, .interrupt:
            if recordingState != nil {
                _ = await handleToggleRecording()
            }
            return .close
        case .exitApp:
            if recordingState != nil {
                _ = await handleToggleRecording()
            }
            return .exitApp
        }
    }

    public func completeExternalAction(_ action: HUDExternalAction, errorMessage: String?) async {
        if let errorMessage {
            lastMessage = "\(failureMessagePrefix(for: action)): \(errorMessage)"
            return
        }

        await refreshSnapshot(
            successMessage: successMessage(for: action),
            failurePrefix: failureMessagePrefix(for: action)
        )
    }

    private func handleToggleRecording() async -> HUDControllerEffect {
        if recordingState == nil {
            do {
                recordingState = try startHUDRecording(transcriber: dependencies.transcriber)
                reviewNote = nil
                reviewState = nil
                lastMessage = "Recording started. Press x again to stop."
            } catch {
                lastMessage = "Failed to start recording: \(error)"
            }
            return .none
        }

        do {
            guard let state = recordingState else { return .none }
            recordingState = nil
            let note = try await stopHUDRecording(
                transcriber: dependencies.transcriber,
                storage: dependencies.storage,
                state: state,
                autoProcessAfterRecord: autoProcessAfterRecord,
                notifyNewTask: {
                    await self.dependencies.queueSupervisor.notifyNewTask()
                }
            )
            reviewNote = note
            reviewState = makeHUDReviewState(from: note)
            await refreshSnapshot(
                successMessage: "Recording saved as [\(note.shortID)].",
                failurePrefix: "Refresh failed"
            )
        } catch {
            recordingState = nil
            lastMessage = "Failed to stop recording: \(error)"
        }
        return .none
    }

    private func handleCancelRecording() async -> HUDControllerEffect {
        guard let state = recordingState else { return .none }
        recordingState = nil
        await cancelHUDRecording(transcriber: dependencies.transcriber, state: state)
        reviewNote = nil
        reviewState = nil
        lastMessage = "Recording canceled."
        return .none
    }

    private func handleRequestEditLastTranscript() -> HUDControllerEffect {
        guard let note = reviewNote else {
            lastMessage = "No saved recording to edit."
            return .none
        }
        return .promptTranscriptEdit(
            HUDTranscriptEditContext(shortID: note.shortID, currentText: note.text)
        )
    }

    private func handleApplyTranscriptEdit(_ text: String?) async -> HUDControllerEffect {
        guard var note = reviewNote else {
            lastMessage = "No saved recording to edit."
            return .none
        }
        guard let text else {
            lastMessage = "Edit canceled."
            return .none
        }

        do {
            note.text = text
            try await dependencies.storage.updateNote(note)
            reviewNote = note
            reviewState = makeHUDReviewState(from: note)
            await refreshSnapshot(
                successMessage: "Transcript updated for [\(note.shortID)].",
                failurePrefix: "Refresh failed"
            )
        } catch {
            lastMessage = "Edit failed: \(error)"
        }
        return .none
    }

    private func handleDeleteLastNote() async -> HUDControllerEffect {
        guard let note = reviewNote else {
            lastMessage = "No saved recording to delete."
            return .none
        }

        do {
            try await dependencies.storage.deleteNote(id: note.id)
            reviewNote = nil
            reviewState = nil
            await refreshSnapshot(
                successMessage: "Deleted note [\(note.shortID)].",
                failurePrefix: "Refresh failed"
            )
        } catch {
            lastMessage = "Delete failed: \(error)"
        }
        return .none
    }

    private func refreshSnapshot(successMessage: String, failurePrefix: String) async {
        do {
            snapshot = try await dependencies.loadSnapshot()
            lastMessage = successMessage
        } catch {
            lastMessage = "\(failurePrefix): \(error)"
        }
    }

    private func successMessage(for action: HUDExternalAction) -> String {
        switch action {
        case .processQueue:
            return "Queue processing completed."
        case .exportNotes:
            return "Export completed."
        case .showStats:
            return "Stats updated."
        case .listRecent:
            return "Recent notes listed."
        }
    }

    private func failureMessagePrefix(for action: HUDExternalAction) -> String {
        switch action {
        case .processQueue:
            return "Queue processing failed"
        case .exportNotes:
            return "Export failed"
        case .showStats:
            return "Stats failed"
        case .listRecent:
            return "List failed"
        }
    }
}
