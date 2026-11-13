import Foundation

public struct HUDRecordingState: Sendable {
    public let startedAt: Date
    public let liveTranscript: HUDLiveTranscript
    public let drainTask: Task<Void, Never>

    public init(startedAt: Date, liveTranscript: HUDLiveTranscript, drainTask: Task<Void, Never>) {
        self.startedAt = startedAt
        self.liveTranscript = liveTranscript
        self.drainTask = drainTask
    }
}

public actor HUDLiveTranscript {
    private var latest = ""

    public init() {}

    public func update(with partial: String) {
        latest = partial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func latestValue() -> String? {
        guard !latest.isEmpty else { return nil }
        return latest
    }

    public func preview(maxLength: Int) -> String? {
        guard !latest.isEmpty else { return nil }
        if latest.count <= maxLength { return latest }
        return String(latest.suffix(maxLength))
    }
}

public func startHUDRecording(transcriber: any TranscriptionPort) throws -> HUDRecordingState {
    let stream = try transcriber.startStreamingCapture()
    let liveTranscript = HUDLiveTranscript()
    let drainTask = Task {
        do {
            for try await partial in stream {
                await liveTranscript.update(with: partial)
            }
        } catch {
            // Keep the caller responsive; stop action surfaces final adapter errors.
        }
    }
    return HUDRecordingState(startedAt: Date(), liveTranscript: liveTranscript, drainTask: drainTask)
}

public func stopHUDRecording(
    transcriber: any TranscriptionPort,
    storage: any StoragePort,
    state: HUDRecordingState,
    autoProcessAfterRecord: Bool,
    notifyNewTask: @Sendable () async -> Void = {}
) async throws -> CapturedNote {
    let (data, finalText) = try await transcriber.stopCapture()
    state.drainTask.cancel()
    await state.drainTask.value

    let transcript = await resolveRecordedTranscript(
        finalText: finalText,
        liveFallback: state.liveTranscript.latestValue()
    )
    let fileName = "hud_recording_\(Int(Date().timeIntervalSince1970)).m4a"
    let note = try await storage.saveRecording(
        data: data,
        fileName: fileName,
        initialText: transcript
    )

    if autoProcessAfterRecord {
        await notifyNewTask()
    }
    return note
}

public func stopHUDRecording(
    transcriber: any TranscriptionPort,
    storage: any StoragePort,
    recordingState: inout HUDRecordingState?,
    autoProcessAfterRecord: Bool,
    notifyNewTask: @Sendable () async -> Void = {}
    ) async throws -> CapturedNote {
    guard let state = recordingState else {
        throw NSError(
            domain: "WimmHUD",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No active recording."]
        )
    }
    recordingState = nil

    return try await stopHUDRecording(
        transcriber: transcriber,
        storage: storage,
        state: state,
        autoProcessAfterRecord: autoProcessAfterRecord,
        notifyNewTask: notifyNewTask
    )
}

public func cancelHUDRecording(
    transcriber: any TranscriptionPort,
    state: HUDRecordingState
) async {
    _ = try? await transcriber.stopCapture()
    state.drainTask.cancel()
    await state.drainTask.value
}

public func cancelHUDRecording(
    transcriber: any TranscriptionPort,
    recordingState: inout HUDRecordingState?
) async {
    guard let state = recordingState else { return }
    recordingState = nil
    await cancelHUDRecording(transcriber: transcriber, state: state)
}

public func resolveRecordedTranscript(finalText: String, liveFallback: String?) -> String {
    let trimmedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedFinal.isEmpty { return finalText }
    if let liveFallback {
        let trimmedLive = liveFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLive.isEmpty { return liveFallback }
    }
    return ""
}
