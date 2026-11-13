import Foundation
import WimmDomain
import WimmInfrastructure

/// The evening note on disk: an ordinary `.md` library note with a `journal`
/// key in its sidecar. One note per evening; reopening finds it by
/// `journal.date`, never by creation time.
enum EveningJournalStore {
    static let metadataKey = "journal"

    struct Entry: Equatable {
        let file: URL
        var body: String
        /// `journal.digest.text`: the digest as last generated. Equal to the
        /// current "День" body means the owner has not touched it.
        var generatedDigest: String?
        var prompts: [String]
        var closedAt: Date?
    }

    // MARK: - Find / create

    /// The evening note for `day`, if one exists. Only `.md` notes stamped
    /// inside the evening's interval are opened, so this never scans the library.
    static func find(day: Date, directory: URL = FileStore.recordingsDirectory()) -> Entry? {
        let interval = EveningJournal.interval(for: day)
        let key = EveningJournal.dateKey(day)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasSuffix(".md") && $0.hasPrefix("Wimm_") && !$0.contains("_Attach_") }
            .map { directory.appendingPathComponent($0) }
            .filter { url in
                guard let date = FileStore.recordingDateFromFileName(url) else { return false }
                return interval.contains(date)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in candidates {
            let metadata = readMetadata(file)
            guard let journal = metadata[metadataKey] as? [String: Any], journal["date"] as? String == key else { continue }
            if relocateLegacyAnswerAudio(of: file) > 0 { return reload(file) }
            return entry(file: file, metadata: metadata)
        }
        return nil
    }

    static func create(day: Date, now: Date = Date(), directory: URL? = nil) throws -> Entry {
        try FileStore.ensureDirectoryExists()
        try FileManager.default.createDirectory(at: directory ?? FileStore.recordingsDirectory(), withIntermediateDirectories: true)
        let identity = RecordingIdentity(createdAt: now)
        let file = FileStore.newRecordingURL(identity: identity, extension: "md", in: directory)
        let prompts = EveningJournal.prompts(for: day)
        let document = EveningJournal.Document(title: EveningJournal.title(for: day), sections: [])
        try Data(document.markdown.utf8).write(to: file, options: .atomic)
        identity.persist(for: file)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
            metadata["title"] = document.title
            metadata["origin"] = ["source": "studio-evening-journal"]
            metadata[metadataKey] = [
                "date": EveningJournal.dateKey(day),
                "prompts": prompts,
                "source": EveningJournal.promptSource,
            ]
            return true
        }
        return Entry(file: file, body: document.markdown, generatedDigest: nil, prompts: prompts, closedAt: nil)
    }

    static func reload(_ file: URL) -> Entry {
        entry(file: file, metadata: readMetadata(file))
    }

    // MARK: - Write

    /// Writes the body to the `.md` file, and to `noteCard.refined_text`
    /// when an editor or analysis already put one there (that is what the
    /// library shows as the body). Keeps a version in `NoteHistory`.
    static func save(body: String, previous: String, file: URL, digest: (text: String, notes: [String])? = nil,
                     history: NoteVersionStore = NoteVersionStore()) async throws {
        if body != previous {
            try Data(body.utf8).write(to: file, options: .atomic)
        }
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
            var changed = false
            if body != previous, var card = metadata["noteCard"] as? [String: Any], card["refined_text"] is String {
                card["refined_text"] = body
                card["refined_edited_at"] = Date().timeIntervalSinceReferenceDate
                metadata["noteCard"] = card
                changed = true
            }
            if let digest {
                var journal = metadata[metadataKey] as? [String: Any] ?? [:]
                journal["digest"] = [
                    "text": digest.text,
                    "notes": digest.notes,
                    "builtAt": ISO8601.string(from: Date()),
                ]
                metadata[metadataKey] = journal
                changed = true
            }
            return changed
        }
        if body != previous {
            await history.record(previous: previous, new: body, source: .manual, for: file)
        }
    }

    static func markClosed(_ file: URL, at date: Date = Date()) throws {
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
            var journal = metadata[metadataKey] as? [String: Any] ?? [:]
            journal["closedAt"] = ISO8601.string(from: date)
            metadata[metadataKey] = journal
            return true
        }
    }

    // MARK: - Spoken answers

    /// `origin.source` of a spoken answer's own note.
    static let answerOriginSource = "studio-evening-answer"

    /// A spoken answer is its own audio note (one note = one media,
    /// 2026-11-09): an ordinary `Wimm_<time>_<id>.aac` in the library, with
    /// the identity sidecar seeded before capture like any Studio recording.
    /// The evening note links to it under the question; the question itself
    /// lives in the evening note (user decision 2026-11-09) and in the answer
    /// note only as provenance (`origin.journalPrompt`).
    static func newAnswerAudioURL(now: Date = Date(), directory: URL? = nil) throws -> URL {
        try FileStore.ensureDirectoryExists()
        try FileManager.default.createDirectory(at: directory ?? FileStore.recordingsDirectory(),
                                                withIntermediateDirectories: true)
        let identity = RecordingIdentity(createdAt: now)
        let url = FileStore.newRecordingURL(identity: identity, extension: AudioFileSink.fileExtension, in: directory)
        identity.persist(for: url)
        return url
    }

    /// Signs the answer's own note: where it came from, and the live text
    /// heard while recording, stored the way Studio capture stores it.
    static func recordAnswer(_ audio: URL, text: String, prompt: String, day: Date) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) { metadata in
            var origin = metadata["origin"] as? [String: Any] ?? [:]
            origin["source"] = answerOriginSource
            origin["journalDate"] = EveningJournal.dateKey(day)
            origin["journalPrompt"] = prompt
            metadata["origin"] = origin
            if !trimmed.isEmpty {
                var transcription = FileStore.transcriptionDictionary(from: metadata["transcription"]) ?? [:]
                transcription["transcript"] = trimmed
                transcription["localTranscript"] = trimmed
                transcription["speechStatus"] = TranscriptionSpeechStatus.speech.rawValue
                metadata["transcription"] = transcription
            }
            return true
        }
    }

    /// The answer audio shown as inline players: answer notes the evening
    /// note links to under a question or "Мысли", in body order, then answers
    /// recorded before 2026-11-09 that still sit in the note's `attachments`
    /// (read only; the split migration turns them into notes).
    static func answerAudio(of file: URL?, in document: EveningJournal.Document,
                            directory: URL = FileStore.recordingsDirectory()) -> [(url: URL, prompt: String)] {
        var result: [(url: URL, prompt: String)] = []
        for section in document.sections where !section.heading.isEmpty && section.heading != EveningJournal.digestHeading {
            for name in EveningJournal.orderedLinkedMetadataNames(in: section.body) {
                if let audio = audioNote(forMetadataName: name, in: directory) {
                    result.append((audio, section.heading))
                }
            }
        }
        if let file { result += legacyAnswerAudio(of: file) }
        return result
    }

    /// The audio file of the note whose sidecar is `name`, if it is an audio note.
    private static func audioNote(forMetadataName name: String, in directory: URL) -> URL? {
        guard name.hasSuffix(".meta.json") else { return nil }
        let base = String(name.dropLast(".meta.json".count))
        for ext in FileStore.supportedAudioExtensions.sorted() {
            let candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
            if !FileStore.isDerivedAudioFile(candidate), FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Legacy answers in `attachments` (read only)

    /// Answers recorded before 2026-11-09 live outside the recordings
    /// directory, like Evernote's attachments, and are listed only in the
    /// note's `attachments`. A `<note>_Attach_….m4a` beside the note would
    /// join its session, and the library picks audio over the `.md` as the
    /// anchor: the note then read as a failed audio recording.
    static func answerDirectory(for file: URL) -> URL {
        StoragePaths.baseDirectory()
            .appendingPathComponent("Attachments/Journal", isDirectory: true)
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Moves answers recorded before 2026-11-01 evening (as `_Attach_` files
    /// beside the note) into `answerDirectory`, rewriting their sidecar URLs.
    /// It only repoints existing entries; it never adds one.
    @discardableResult
    static func relocateLegacyAnswerAudio(of file: URL) -> Int {
        let base = file.deletingPathExtension().lastPathComponent
        let legacy = legacyAnswerAudio(of: file).filter {
            $0.url.lastPathComponent.hasPrefix(base + "_Attach_")
                && $0.url.deletingLastPathComponent().standardizedFileURL == file.deletingLastPathComponent().standardizedFileURL
        }
        guard !legacy.isEmpty else { return 0 }
        let directory = answerDirectory(for: file)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return 0 }
        var moved: [String: String] = [:]
        for item in legacy {
            let name = "answer-" + String(item.url.lastPathComponent.dropFirst((base + "_Attach_").count))
            let destination = directory.appendingPathComponent(name)
            let fm = FileManager.default
            if fm.fileExists(atPath: item.url.path), !fm.fileExists(atPath: destination.path) {
                guard (try? fm.moveItem(at: item.url, to: destination)) != nil else { continue }
            } else if !fm.fileExists(atPath: destination.path) {
                continue
            }
            moved[StoragePaths.relativePath(for: item.url)] = StoragePaths.relativePath(for: destination)
        }
        guard !moved.isEmpty else { return 0 }
        do {
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
                guard var attachments = metadata["attachments"] as? [[String: Any]] else { return false }
                for index in attachments.indices {
                    if let old = attachments[index]["url"] as? String, let new = moved[old] {
                        attachments[index]["url"] = new
                    }
                }
                metadata["attachments"] = attachments
                return true
            }
        } catch {
            log("[Evening] moved answer audio but could not rewrite \(file.lastPathComponent): \(error.localizedDescription)")
        }
        return moved.count
    }

    /// Answer audio listed in the note's legacy `attachments`.
    static func legacyAnswerAudio(of file: URL) -> [(url: URL, prompt: String)] {
        let attachments = readMetadata(file)["attachments"] as? [[String: Any]] ?? []
        return attachments.compactMap { item in
            guard let prompt = item["journalPrompt"] as? String, let path = item["url"] as? String else { return nil }
            return (StoragePaths.resolveRelativePath(path), prompt)
        }
    }

    // MARK: - Reading

    private static func readMetadata(_ file: URL) -> [String: Any] {
        let url = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private static func entry(file: URL, metadata: [String: Any]) -> Entry {
        let fileText = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let refined = (metadata["noteCard"] as? [String: Any])?["refined_text"] as? String
        let journal = metadata[metadataKey] as? [String: Any] ?? [:]
        let digest = journal["digest"] as? [String: Any]
        return Entry(
            file: file,
            body: refined ?? fileText,
            generatedDigest: digest?["text"] as? String,
            prompts: journal["prompts"] as? [String] ?? [],
            closedAt: (journal["closedAt"] as? String).flatMap { ISO8601.date(from: $0) }
        )
    }
}
