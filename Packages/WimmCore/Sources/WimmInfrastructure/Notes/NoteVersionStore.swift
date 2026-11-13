import Foundation
import WimmDomain

/// One saved state of a note's body text.
public struct NoteVersion: Codable, Identifiable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// The text as it stood before an edit replaced it — the model's
        /// refined text, the transcript, or a change made elsewhere.
        case baseline
        /// Typed in the Reader.
        case manual
        /// An earlier version or a transcript put back as the body.
        case restored
    }

    public let id: UUID
    public var text: String
    public var savedAt: Date
    public var source: Source

    public init(id: UUID = UUID(), text: String, savedAt: Date, source: Source) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
        self.source = source
    }
}

/// Version history of note bodies, one JSON file per note under
/// `<base>/NoteHistory/`.
///
/// Kept out of the `.meta.json` sidecar on purpose: the sidecar is read for
/// every note when the journal is built and is uploaded by CloudSync, and an
/// autosaving editor would grow it with every pause in typing. The history is
/// a local convenience, not canonical note content — losing it loses no note.
public actor NoteVersionStore {
    /// Autosave writes every ~0.8 s of quiet; saves inside this window extend
    /// the same manual version instead of each becoming its own.
    public static let coalesceWindow: TimeInterval = 5 * 60
    public static let versionLimit = 100

    private let directory: URL

    public init(directory: URL = StoragePaths.baseDirectory().appendingPathComponent("NoteHistory")) {
        self.directory = directory
    }

    /// Versions oldest first.
    public func versions(for noteFile: URL) -> [NoteVersion] {
        guard let data = try? Data(contentsOf: historyURL(for: noteFile)) else { return [] }
        return (try? Self.decoder.decode([NoteVersion].self, from: data)) ?? []
    }

    /// Records that the body changed from `previous` to `new`.
    ///
    /// The first edit also keeps `previous` as a baseline, so the text an edit
    /// replaced is always recoverable — including text that changed outside
    /// the editor (a re-analysis) since the last recorded version.
    @discardableResult
    public func record(
        previous: String,
        new: String,
        source: NoteVersion.Source,
        for noteFile: URL,
        now: Date = Date()
    ) -> [NoteVersion] {
        guard previous != new else { return versions(for: noteFile) }
        var history = versions(for: noteFile)

        if !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           history.last?.text != previous {
            history.append(NoteVersion(text: previous, savedAt: now, source: .baseline))
        }

        if let last = history.last, last.text == new {
            return history
        }

        if source == .manual,
           let last = history.last,
           last.source == .manual,
           now.timeIntervalSince(last.savedAt) < Self.coalesceWindow {
            history[history.count - 1].text = new
            history[history.count - 1].savedAt = now
        } else {
            history.append(NoteVersion(text: new, savedAt: now, source: source))
        }

        if history.count > Self.versionLimit {
            // The oldest entry is the closest thing to the original; keep it.
            history.removeSubrange(1...(history.count - Self.versionLimit))
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(history).write(to: historyURL(for: noteFile), options: .atomic)
        } catch {
            log("NoteVersionStore: failed to write history for \(noteFile.lastPathComponent): \(error)")
        }
        return history
    }

    private func historyURL(for noteFile: URL) -> URL {
        directory.appendingPathComponent(noteFile.lastPathComponent + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A transcription of a note's audio other than the body text, labeled by
/// how it was made (`TranscriptKind`): the realtime text captured while
/// recording, the latest on-device file run, the latest cloud file run — plus
/// the current run when its provider is neither, and every other run a
/// re-transcription replaced.
public struct NoteTranscriptVariant: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case realtime
        case local
        case cloud
        /// The current run, when its provider is neither local nor cloud.
        case current
        /// The current transcript split by speaker (`transcription.speakerTurns`); `text` has
        /// `{speaker}` placeholders until `rendered(speakerLabel:)` names them.
        case speakers(count: Int)
        /// An archived run that is not the latest of its kind.
        case previous
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let provider: String?
    public let model: String?
    /// When the run started — nil when unknown (and for realtime text).
    public let date: Date?
    /// The run `transcription.transcript` holds right now — the one the note
    /// was last built from.
    public let isCurrentRun: Bool

    public init(id: String, kind: Kind, text: String, provider: String?, model: String?,
                date: Date?, isCurrentRun: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.provider = provider
        self.model = model
        self.date = date
        self.isCurrentRun = isCurrentRun
    }

    /// Reads every transcription stored in a sidecar: Realtime, Local and
    /// Cloud in that order (each only when present), an unclassified current
    /// run before them, then the remaining archived runs newest first.
    public static func variants(fromSidecar metadata: [String: Any]) -> [NoteTranscriptVariant] {
        let transcription = TranscriptRuns.transcription(fromSidecar: metadata)
        var runs = transcription.map { TranscriptRuns.runs(in: $0) } ?? []

        // Merge any distinct document / image-OCR runs not already present in `transcription`.
        var extraRuns: [TranscriptRun] = []
        if let doc = metadata["document"] as? [String: Any] {
            extraRuns.append(contentsOf: TranscriptRuns.extractionRuns(
                in: doc, textKey: "text", providerKey: "textProvider", modelKey: "textModel"
            ))
        }
        if let ocr = metadata["ocr"] as? [String: Any],
           (ocr["source"] as? String) != "screenshot" {
            extraRuns.append(contentsOf: TranscriptRuns.extractionRuns(
                in: ocr, textKey: "text", providerKey: "provider", modelKey: "model"
            ))
        }
        let hasCurrentInTranscription = runs.contains(where: \.isCurrent)
        var nextExtraArchiveIndex = (runs.compactMap(\.archiveIndex).max() ?? -1) + 1
        for extra in extraRuns where !runs.contains(where: { $0.text == extra.text }) {
            let isCurrent = extra.isCurrent && !hasCurrentInTranscription && !runs.contains(where: \.isCurrent)
            let archiveIdx: Int? = isCurrent ? nil : {
                defer { nextExtraArchiveIndex += 1 }
                return nextExtraArchiveIndex
            }()
            runs.append(TranscriptRun(
                text: extra.text,
                provider: extra.provider,
                model: extra.model,
                startedAt: extra.startedAt,
                isCurrent: isCurrent,
                archiveIndex: archiveIdx
            ))
        }

        guard transcription != nil || !runs.isEmpty else { return [] }
        var result: [NoteTranscriptVariant] = []

        if let index = runs.firstIndex(where: { $0.isCurrent && $0.kind == nil }) {
            result.append(variant(runs.remove(at: index), id: "current", kind: .current))
        }
        if let transcription, let text = TranscriptRuns.realtime(in: transcription) {
            result.append(NoteTranscriptVariant(
                id: "realtime", kind: .realtime, text: text,
                provider: nil, model: nil, date: nil,
                isCurrentRun: TranscriptRuns.isRealtimeCopy(transcription)))
        }
        if let transcription,
           let record = SpeakerTurnsRecord(sidecarValue: transcription[SpeakerTurnsRecord.sidecarKey]),
           record.isMultiSpeaker {
            result.append(NoteTranscriptVariant(
                id: "speakers", kind: .speakers(count: record.speakers),
                text: SpeakerTurns.render(record.turns) { speakerPlaceholder($0) },
                provider: "parakeet", model: record.engine, date: record.createdAt,
                isCurrentRun: false))
        }
        for (kind, slot) in [(TranscriptKind.local, Kind.local), (.cloud, .cloud)] {
            if let index = runs.firstIndex(where: { $0.kind == kind }) {
                result.append(variant(runs.remove(at: index), id: kind.rawValue, kind: slot))
            }
        }
        for run in runs {
            result.append(variant(run, id: "previous-\(run.archiveIndex ?? -1)", kind: .previous))
        }
        return result
    }

    private static func variant(_ run: TranscriptRun, id: String, kind: Kind) -> NoteTranscriptVariant {
        NoteTranscriptVariant(id: id, kind: kind, text: run.text, provider: run.provider,
                              model: run.model, date: run.startedAt, isCurrentRun: run.isCurrent)
    }

    /// Replaces the `{speaker:N}` placeholders of a `.speakers` variant with readable labels.
    public func rendered(speakerLabel: (Int) -> String) -> NoteTranscriptVariant {
        guard case .speakers = kind else { return self }
        var text = text
        var number = 1
        while text.contains(Self.speakerPlaceholder(number)) {
            text = text.replacingOccurrences(of: Self.speakerPlaceholder(number), with: speakerLabel(number))
            number += 1
        }
        return NoteTranscriptVariant(id: id, kind: kind, text: text, provider: provider, model: model, date: date,
                                     isCurrentRun: isCurrentRun)
    }

    static func speakerPlaceholder(_ number: Int) -> String { "{speaker:\(number)}" }

    public static func variants(forNoteFile file: URL) -> [NoteTranscriptVariant] {
        let url = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return variants(fromSidecar: json)
    }
}
