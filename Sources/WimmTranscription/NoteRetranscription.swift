import Foundation
import WimmDomain
import WimmInfrastructure

/// The one retranscription run behind `transcript retranscribe` and the MCP
/// queue worker. The sidecar is written only by `TranscriptionService`
/// (`recordRunSuccess` under `FileStore.mutateSidecar`): the replaced text
/// moves to `transcription.previousRuns`, and a no-speech verdict never
/// replaces earlier text.
public enum NoteRetranscription {
    public struct Outcome: Sendable {
        public var failed: Bool
        public var summary: String
    }

    /// Non-nil when private mode forbids this model: only on-device Parakeet
    /// keeps the audio on the Mac.
    public static func privateModeRefusal(model: String) -> String? {
        guard PrivateMode.isEnabled, !ParakeetModel.isParakeet(model) else { return nil }
        return "private mode: \(model) would send the audio to the cloud — use parakeet:ultra or turn private mode off"
    }

    /// Words in the transcript the sidecar holds now (read only).
    public static func storedWordCount(file: URL) -> Int {
        let transcript = (try? Data(contentsOf: FileStore.metadataURL(forRecordingURL: file)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["transcription"] as? [String: Any])?["transcript"] as? String } ?? ""
        return wordCount(transcript)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// `attachmentOf` + `attachmentID`: `file` is an audio attachment of that
    /// note (an Evernote import). The transcription service still keeps the
    /// attachment's own run history next to the file; the text the note shows,
    /// searches and analyzes is the attachment entry in the note's sidecar,
    /// set by `NoteAttachmentMedia.setText` (a no-speech verdict never replaces
    /// it), and the analysis runs on the note.
    public static func run(
        file: URL,
        model: String,
        language: String = "Auto",
        analyze: Bool,
        attachmentOf parent: URL? = nil,
        attachmentID: UUID? = nil,
        requestContext: [String: String]
    ) async -> Outcome {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Outcome(failed: true, summary: "recording file missing")
        }
        if let refusal = privateModeRefusal(model: model) {
            return Outcome(failed: true, summary: refusal)
        }
        if let parent {
            guard let attachmentID else { return Outcome(failed: true, summary: "attachment id missing") }
            return await runAttachment(file: file, parent: parent, attachmentID: attachmentID, model: model,
                                       language: language, analyze: analyze, requestContext: requestContext)
        }
        let oldWords = storedWordCount(file: file)
        // A model id with a slash is an OpenRouter one; everything else
        // (Gemini ids, parakeet:) takes the Gemini route, as `transcript retry` does.
        let engine: EngineID = model.contains("/") ? .openrouter : .gemini
        let service = TranscriptionService(rotator: .shared, model: model, transport: .shared)
        let result = await service.transcribe(file: file, engine: engine, model: model, language: language)
        switch result {
        case .success(let text):
            let words = wordCount(text)
            guard words > 0 else {
                // recordRunSuccess never lets a no-speech verdict replace text,
                // so the sidecar may still hold the old (possibly made-up) one.
                return Outcome(failed: false, summary: oldWords > 0
                    ? "no_speech — the earlier transcript (\(oldWords) words) was kept; if it is made up, clear it with wimm-cli transcript clear-no-speech"
                    : "no_speech")
            }
            var summary = "speech: \(oldWords) → \(words) words (\(text.count) chars)"
            if analyze {
                do {
                    _ = try await NoteProcessor.shared.reprocess(file: file, requestContext: requestContext)
                    summary += "; analyzed"
                } catch {
                    summary += "; analysis failed: \(error.localizedDescription)"
                }
            }
            return Outcome(failed: false, summary: summary)
        case .failure(let reason, let underlying):
            return Outcome(failed: true, summary: "\(reason)" + (underlying.map { ": \($0.localizedDescription)" } ?? ""))
        }
    }
}

extension NoteRetranscription {
    fileprivate static func runAttachment(
        file: URL,
        parent: URL,
        attachmentID: UUID,
        model: String,
        language: String,
        analyze: Bool,
        requestContext: [String: String]
    ) async -> Outcome {
        guard let item = NoteAttachmentMedia.items(ofNote: parent).first(where: { $0.id == attachmentID }) else {
            return Outcome(failed: true, summary: "attachment no longer listed on the note")
        }
        let oldWords = item.hasMeaningfulText ? wordCount(item.text ?? "") : 0
        let engine: EngineID = model.contains("/") ? .openrouter : .gemini
        let service = TranscriptionService(rotator: .shared, model: model, transport: .shared)
        let result = await service.transcribe(file: file, engine: engine, model: model, language: language)
        switch result {
        case .success(let text):
            let provider = ParakeetModel.isParakeet(model) ? "parakeet" : engine.rawValue
            let written: NoteAttachmentMedia.WriteResult
            do {
                written = try NoteAttachmentMedia.setText(
                    text, provider: provider, model: model, attachmentID: attachmentID, ofNote: parent)
            } catch {
                return Outcome(failed: true, summary: "could not write the note: \(error.localizedDescription)")
            }
            let words = wordCount(text)
            switch written {
            case .attachmentMissing:
                return Outcome(failed: true, summary: "attachment no longer listed on the note")
            case .keptExisting:
                return Outcome(failed: false, summary: "no_speech — the earlier attachment transcript (\(oldWords) words) was kept")
            case .written where words == 0:
                return Outcome(failed: false, summary: "no_speech")
            case .written:
                var summary = "speech: \(oldWords) → \(words) words (\(text.count) chars)"
                if analyze {
                    do {
                        _ = try await NoteProcessor.shared.reprocess(file: parent, requestContext: requestContext)
                        summary += "; note analyzed"
                    } catch {
                        summary += "; analysis failed: \(error.localizedDescription)"
                    }
                }
                return Outcome(failed: false, summary: summary)
            }
        case .failure(let reason, let underlying):
            return Outcome(failed: true, summary: "\(reason)" + (underlying.map { ": \($0.localizedDescription)" } ?? ""))
        }
    }
}


/// Works off `RetranscriptionQueue` one entry at a time until it is empty.
/// Shared by `wimm-cli transcript drain-queue` and Studio, which drains it in
/// its own process: the worker lock keeps it to one worker at a time, and an
/// entry left `running` by a worker that died goes back to the queue.
public enum RetranscriptionWorker {
    /// Returns nil when another worker holds the lock, else the entries done.
    public static func drain(
        queue: RetranscriptionQueue = RetranscriptionQueue(),
        origin: String,
        defaultReason: String,
        allowsAnalysis: Bool = true,
        report: (RetranscriptionQueue.Entry, NoteRetranscription.Outcome?) -> Void = { _, _ in }
    ) async throws -> Int? {
        try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
        let lock = open(queue.workerLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(lock, LOCK_UN) }

        let pid = getpid()
        var done = 0
        while let entry = try queue.claimNext(pid: pid) {
            report(entry, nil)
            let outcome = await NoteRetranscription.run(
                file: URL(fileURLWithPath: entry.file),
                model: entry.model,
                analyze: allowsAnalysis && entry.analyze,
                attachmentOf: entry.parentFile.map { URL(fileURLWithPath: $0) },
                attachmentID: entry.attachmentID.flatMap(UUID.init(uuidString:)),
                requestContext: [
                    "origin": origin,
                    "reason": entry.reason ?? defaultReason,
                ]
            )
            try queue.finish(entry, failed: outcome.failed, outcome: outcome.summary)
            report(entry, outcome)
            done += 1
        }
        return done
    }
}
