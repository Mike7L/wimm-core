import Foundation
import WimmDomain

/// Retranscriptions an agent asked for (`request_retranscription`), worked
/// off one at a time by `wimm-cli transcript drain-queue` — a detached
/// process, so a run survives the agent's session ending. The result lands
/// in the note's sidecar through the ordinary transcription path (the
/// replaced text moves to `transcription.previousRuns`), which is what makes
/// it show up in `changed_notes`; this queue keeps the outcome, including the
/// ones that leave the sidecar untouched (a no-speech verdict never replaces
/// earlier text).
///
/// `<base>/AgentState/retranscription-queue.json`, local only.
public struct RetranscriptionQueue: Sendable {
    public let directory: URL

    public init(directory: URL = StoragePaths.baseDirectory().appendingPathComponent("AgentState")) {
        self.directory = directory
    }

    public struct Entry: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case queued, running, done, failed
        }

        /// The audio file to transcribe: the note's own recording, or one of
        /// its audio attachments (then `parentFile` is the note).
        public var file: String
        public var noteId: String
        /// The note an attachment entry belongs to (an Evernote `.txt` note);
        /// nil for a note's own recording.
        public var parentFile: String?
        public var attachmentID: String?
        public var model: String
        public var analyze: Bool
        public var reason: String?
        public var requestedAt: Date
        public var state: State
        public var startedAt: Date?
        public var finishedAt: Date?
        /// pid of the worker running it — a dead pid puts it back in the queue.
        public var workerPID: Int32?
        /// `speech: 1234 chars` / `no_speech (earlier text kept)` / the failure.
        public var outcome: String?

        public init(
            file: String, noteId: String, model: String, analyze: Bool, reason: String?, requestedAt: Date,
            parentFile: String? = nil, attachmentID: String? = nil
        ) {
            self.file = file
            self.noteId = noteId
            self.parentFile = parentFile
            self.attachmentID = attachmentID
            self.model = model
            self.analyze = analyze
            self.reason = reason
            self.requestedAt = requestedAt
            self.state = .queued
        }

        public var isOpen: Bool { state == .queued || state == .running }
    }

    /// Finished entries kept for the agent to read back.
    static let finishedLimit = 500

    struct Document: Codable {
        var schema = "RetranscriptionQueue@v1"
        var entries: [Entry] = []
    }

    private var url: URL { directory.appendingPathComponent("retranscription-queue.json") }

    public func entries() -> [Entry] { read().entries }

    /// The newest entry for this recording file (by full path).
    public func latest(forFile path: String) -> Entry? {
        read().entries.last { $0.file == path }
    }

    /// The newest entry for this note: its own recording or one of its attachments.
    public func latest(forNote path: String) -> Entry? {
        read().entries.last { $0.file == path || $0.parentFile == path }
    }

    public enum EnqueueResult: Equatable, Sendable {
        case queued
        case alreadyOpen(Entry)
    }

    /// Adds requests; a file that already has an open one keeps it.
    public func enqueue(_ requests: [Entry]) throws -> [EnqueueResult] {
        try mutate { doc in
            requests.map { request in
                if let open = doc.entries.last(where: { $0.file == request.file && $0.isOpen }) {
                    return .alreadyOpen(open)
                }
                doc.entries.append(request)
                return .queued
            }
        }
    }

    /// Marks the oldest queued entry as running under `pid` and returns it.
    /// Entries left `running` by a worker that died go back to the queue first.
    public func claimNext(pid: Int32, now: Date = Date(), isAlive: (Int32) -> Bool = Self.isAlive) throws -> Entry? {
        try mutate { doc in
            for i in doc.entries.indices where doc.entries[i].state == .running {
                if let worker = doc.entries[i].workerPID, worker != pid, !isAlive(worker) {
                    doc.entries[i].state = .queued
                    doc.entries[i].workerPID = nil
                }
            }
            guard let i = doc.entries.firstIndex(where: { $0.state == .queued }) else { return nil }
            doc.entries[i].state = .running
            doc.entries[i].startedAt = now
            doc.entries[i].workerPID = pid
            return doc.entries[i]
        }
    }

    public func finish(_ entry: Entry, failed: Bool, outcome: String, now: Date = Date()) throws {
        try mutate { doc in
            guard let i = doc.entries.lastIndex(where: {
                $0.file == entry.file && $0.requestedAt == entry.requestedAt
            }) else { return }
            doc.entries[i].state = failed ? .failed : .done
            doc.entries[i].finishedAt = now
            doc.entries[i].workerPID = nil
            doc.entries[i].outcome = outcome
        }
    }

    public var hasQueued: Bool { read().entries.contains { $0.state == .queued } }

    func read() -> Document {
        guard let data = try? Data(contentsOf: url) else { return Document() }
        return (try? AgentMarkStore.decoder.decode(Document.self, from: data)) ?? Document()
    }

    private func mutate<T>(_ change: (inout Document) -> T) throws -> T {
        try AgentStateLock.withLock(in: directory, name: "retranscription-queue") {
            var doc = read()
            let result = change(&doc)
            let finished = doc.entries.indices.filter { !doc.entries[$0].isOpen }
            if finished.count > Self.finishedLimit {
                let drop = Set(finished.prefix(finished.count - Self.finishedLimit))
                doc.entries = doc.entries.indices.filter { !drop.contains($0) }.map { doc.entries[$0] }
            }
            try AgentMarkStore.encoder.encode(doc).write(to: url, options: .atomic)
            return result
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Held by the one worker draining the queue; a second worker exits.
    public var workerLockURL: URL { directory.appendingPathComponent(".retranscription-worker.lock") }
}
