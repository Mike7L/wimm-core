import Foundation
import Observation
import WimmDomain
import WimmInfrastructure

/// State of the evening window: the day's notes, the evening note being
/// written, and the prepared "День" digest. The note is created on the first
/// real change, so opening the window and closing it leaves nothing behind.
@MainActor @Observable
final class EveningModel {
    let day: Date
    let interval: DateInterval
    private(set) var file: URL?
    /// The note as written: what is on disk after the last save.
    private(set) var savedBody = ""
    var document: EveningJournal.Document
    private(set) var generatedDigest: String?
    let prompts: [String]
    private(set) var dayNotes: [EveningJournal.DayNote] = []
    private(set) var closedAt: Date?
    private(set) var answerAudio: [(url: URL, prompt: String)] = []
    var errorMessage: String?

    @ObservationIgnored var onNoteChanged: (([URL]) -> Void)?
    /// A spoken answer's own audio note is saved; the host asks for its local file run.
    @ObservationIgnored var onAnswerRecorded: ((URL) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// A real edit is waiting to be written; without one an unwritten evening stays unwritten.
    @ObservationIgnored private var hasPendingEdit = false

    init(day: Date) {
        self.day = day
        interval = EveningJournal.interval(for: day)
        if let entry = EveningJournalStore.find(day: day) {
            file = entry.file
            savedBody = entry.body
            var parsed = EveningJournal.Document(markdown: entry.body)
            if parsed.title.isEmpty { parsed.title = EveningJournal.title(for: day) }
            document = parsed
            generatedDigest = entry.generatedDigest
            prompts = entry.prompts.isEmpty ? EveningJournal.prompts(for: day) : entry.prompts
            closedAt = entry.closedAt
            answerAudio = EveningJournalStore.answerAudio(of: entry.file, in: parsed)
        } else {
            document = EveningJournal.Document(title: EveningJournal.title(for: day), sections: [])
            prompts = EveningJournal.prompts(for: day)
        }
    }

    // MARK: - Day notes and digest

    /// Called whenever the library changes. A digest nobody has edited follows
    /// the library; an edited one only offers what is missing (`missingLines`).
    func update(notes: [StudioLibraryNote]) {
        let ownBase = file?.deletingPathExtension().lastPathComponent
        let cited = EveningJournal.citedMetadataNames(in: document)
        dayNotes = notes.compactMap { note in
            guard interval.contains(note.absoluteDate),
                  note.fileURL.deletingPathExtension().lastPathComponent != ownBase else { return nil }
            let kind: EveningJournal.DayNote.Kind = switch note.kind {
            case .voice: .voice
            case .text: .text
            case .image: .image
            case .pdf: .pdf
            }
            let metadata = note.metadataURL ?? FileStore.metadataURL(forRecordingURL: note.fileURL)
            // A spoken answer is already under its question.
            guard !cited.contains(metadata.lastPathComponent) else { return nil }
            return EveningJournal.DayNote(date: note.absoluteDate, title: note.studioTitle, kind: kind,
                                          metadataName: metadata.lastPathComponent, minutes: note.minutes)
        }.sorted { $0.date < $1.date }
        if isDigestUntouched {
            let fresh = EveningJournal.digestMarkdown(EveningJournal.digest(dayNotes))
            if document.body(of: EveningJournal.digestHeading) != fresh {
                document.setBody(fresh, of: EveningJournal.digestHeading)
                generatedDigest = fresh
                // A note that already exists follows too; an unwritten one waits for a real change.
                if file != nil { scheduleSave() }
            }
        }
    }

    var digestBody: String { document.body(of: EveningJournal.digestHeading) ?? "" }

    /// No digest yet, or the one on screen is exactly what was generated.
    var isDigestUntouched: Bool {
        guard let current = document.body(of: EveningJournal.digestHeading) else { return true }
        return current == generatedDigest || current.isEmpty
    }

    /// Notes of the day an edited digest does not link to yet.
    var missingLines: [EveningJournal.DigestLine] {
        guard !isDigestUntouched else { return [] }
        let linked = EveningJournal.linkedMetadataNames(in: digestBody)
        let missing = dayNotes.filter { !linked.contains($0.metadataName) }
        return EveningJournal.digest(missing)
    }

    func addMissingLines() {
        let lines = EveningJournal.digestMarkdown(missingLines)
        guard !lines.isEmpty else { return }
        let body = digestBody.isEmpty ? lines : digestBody + "\n" + lines
        setBody(body, of: EveningJournal.digestHeading)
    }

    func rebuildDigest() {
        let fresh = EveningJournal.digestMarkdown(EveningJournal.digest(dayNotes))
        generatedDigest = fresh
        document.setBody(fresh, of: EveningJournal.digestHeading)
        scheduleSave()
    }

    // MARK: - Editing

    func body(of heading: String) -> String { document.body(of: heading) ?? "" }

    func setBody(_ text: String, of heading: String) {
        guard text != body(of: heading) else { return }
        document.setBody(text, of: heading)
        scheduleSave()
    }

    func appendSpoken(_ text: String, to heading: String) {
        let current = body(of: heading)
        setBody(current.isEmpty ? text : current + "\n\n" + text, of: heading)
    }

    /// Writes one second after the last keystroke.
    func scheduleSave() {
        hasPendingEdit = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// `creating` writes the note even with nothing edited (closing the day is a real act).
    func saveNow(creating: Bool = false) async {
        saveTask?.cancel(); saveTask = nil
        guard file != nil || hasPendingEdit || creating else { return }
        let body = document.droppingEmptyQuestions().markdown
        guard body != savedBody || file == nil else { return }
        do {
            let file = try ensureFile()
            let digest = generatedDigest.map { text in
                (text: text, notes: Array(EveningJournal.linkedMetadataNames(in: text)).sorted())
            }
            try await EveningJournalStore.save(body: body, previous: savedBody, file: file, digest: digest)
            savedBody = body
            hasPendingEdit = false
            errorMessage = nil
            onNoteChanged?([file])
        } catch {
            errorMessage = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    /// The evening note, created on first need.
    func ensureFile() throws -> URL {
        if let file { return file }
        let entry = try EveningJournalStore.create(day: day)
        file = entry.file
        savedBody = entry.body
        return entry.file
    }

    /// A finished spoken answer: its own audio note is signed, and the text
    /// as heard goes under the question with a link to that note.
    func attachAnswer(audio: URL, text: String, prompt: String) {
        do {
            try EveningJournalStore.recordAnswer(audio, text: text, prompt: prompt, day: day)
        } catch {
            errorMessage = "Ответ сохранён, но не подписан: \(error.localizedDescription)"
        }
        let name = FileStore.metadataURL(forRecordingURL: audio).lastPathComponent
        appendSpoken(EveningJournal.answerMarkdown(text: text, metadataName: name), to: prompt)
        answerAudio = EveningJournalStore.answerAudio(of: file, in: document)
        onNoteChanged?([audio])
        onAnswerRecorded?(audio)
    }

    func closeDay() async {
        await saveNow(creating: true)
        guard let file else { return }
        do {
            try EveningJournalStore.markClosed(file)
            closedAt = Date()
            onNoteChanged?([file])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
