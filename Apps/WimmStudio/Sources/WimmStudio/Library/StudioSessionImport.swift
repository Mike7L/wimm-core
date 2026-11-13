import Foundation
import SQLite3
import WimmDomain
import WimmInfrastructure

/// Imports a snapshot after the source has been idle for an hour, and
/// rewrites the note when an imported chat was continued and went idle again.
actor StudioSessionImport {
    private enum Source: String, Hashable {
        case codex = "Codex"
        case claude = "Claude"
        case cursor = "Cursor"
        case antigravity = "Antigravity"

        var marker: String { "Сессия \(rawValue) " }

        func id(for file: URL) -> UUID? {
            let name = file.deletingPathExtension().lastPathComponent
            if self == .codex {
                guard name.hasPrefix("rollout-") else { return nil }
                return UUID(uuidString: String(name.suffix(36)))
            }
            // Cursor: <uuid>/<uuid>.jsonl; Antigravity: <uuid>.db.
            return UUID(uuidString: name)
        }
    }

    private let home: URL
    private let recordings: URL
    private var imported: [UUID: URL]?
    private var ignoredVersions: [URL: Date] = [:]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        recordings: URL = FileStore.recordingsDirectory()
    ) {
        self.home = home
        self.recordings = recordings
    }

    func run(now: Date = Date()) -> [URL] {
        guard !PrivateMode.isEnabled else { return [] }
        if imported == nil { imported = existingSessions() }

        let cutoff = now.addingTimeInterval(-3600)
        var files: [URL] = []
        for (source, file) in candidates() {
            guard !Task.isCancelled, !PrivateMode.isEnabled else { break }
            guard let id = source.id(for: file),
                  let modified = modificationDate(file), modified <= cutoff,
                  ignoredVersions[file] != modified else { continue }
            // The note was written after its chat went idle; a newer log means the chat went on.
            let note = imported?[id]
            if let note {
                guard let written = modificationDate(note), modified > written else { continue }
            }
            do {
                let session = try read(file, source: source)
                // A CLI can resume the chat while its log is being read.
                guard modificationDate(file) == modified, !PrivateMode.isEnabled else { continue }
                guard let session else {
                    ignoredVersions[file] = modified
                    continue
                }
                if let note {
                    if try update(note, with: session, source: source, id: id) {
                        files.append(note)
                    } else {
                        ignoredVersions[file] = modified
                    }
                    continue
                }
                let saved = try save(session, source: source, id: id)
                imported?[id] = saved.file
                if saved.isNew { files.append(saved.file) }
            } catch {
                log("[SessionImport] \(source.rawValue) \(id): \(error.localizedDescription)")
            }
        }
        return files
    }

    private func candidates() -> [(Source, URL)] {
        let fm = FileManager.default
        var files: [(Source, URL)] = []
        files += externalCandidates()
        for directory in [".codex/sessions", ".codex/archived_sessions", ".claude/projects"] {
            let source: Source = directory == ".claude/projects" ? .claude : .codex
            let root = home.appendingPathComponent(directory)
            guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [
                .isRegularFileKey, .contentModificationDateKey,
            ], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in entries {
                if source == .claude && entries.level == 2 {
                    // Project subdirectories contain subagents and tool artifacts.
                    entries.skipDescendants()
                }
                guard file.pathExtension == "jsonl", source != .claude || entries.level == 2,
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files.append((source, file))
            }
        }
        return files
    }

    /// Cursor keeps `<project>/agent-transcripts/<id>/<id>.jsonl`; Antigravity keeps one SQLite file per chat.
    private func externalCandidates() -> [(Source, URL)] {
        let fm = FileManager.default
        var files: [(Source, URL)] = []
        let projects = home.appendingPathComponent(".cursor/projects")
        for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        where !project.lastPathComponent.hasPrefix(".") && !project.lastPathComponent.contains("secretary-runs") {
            let root = project.appendingPathComponent("agent-transcripts")
            for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let file = folder.appendingPathComponent(folder.lastPathComponent + ".jsonl")
                if fm.fileExists(atPath: file.path) { files.append((.cursor, file)) }
            }
        }
        let conversations = home.appendingPathComponent(".gemini/antigravity/conversations")
        for file in (try? fm.contentsOfDirectory(at: conversations, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "db" { files.append((.antigravity, file)) }
        return files
    }

    private func modificationDate(_ file: URL) -> Date? {
        // Fresh URL avoids values cached by the enumerator.
        let dates = [file.path, file.path + "-wal"].compactMap {
            try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max()
    }

    /// The CLI batch imports carry the same session ID on the second nonempty line.
    private func existingSessions() -> [UUID: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil)) ?? []
        var ids: [UUID: URL] = [:]
        for file in files where file.pathExtension == "txt" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let bytes = try? handle.read(upToCount: 1024) else { continue }
            let lines = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline)
            guard lines.count >= 2, lines[0].hasPrefix("# ") else { continue }
            for source in [Source.codex, .claude, .cursor, .antigravity] where lines[1].hasPrefix(source.marker) {
                if let id = UUID(uuidString: String(lines[1].dropFirst(source.marker.count))) {
                    ids[id] = file
                }
            }
        }
        return ids
    }

    private struct Session {
        let date: Date
        let title: String
        let dialogue: String
    }

    private func read(_ file: URL, source: Source) throws -> Session? {
        if source == .antigravity { return try readAntigravity(file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var buffer = Data()
        var dialogue: [String] = []
        var date: Date?
        var firstPrompt: String?
        var title: String?
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSeconds = ISO8601DateFormatter()

        func parseDate(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return timestamp.date(from: text) ?? wholeSeconds.date(from: text)
        }

        func consume(_ line: Data) throws -> Bool {
            guard let row = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
            let payload = row["payload"] as? [String: Any] ?? [:]
            let cwd = source == .codex ? payload["cwd"] : row["cwd"]
            if let path = cwd as? String, (path + "/").contains("/secretary/runs/") { return false }
            if source == .codex, row["type"] as? String == "session_meta" {
                if (payload["source"] as? [String: Any])?["subagent"] != nil { return false }
                date = parseDate(payload["timestamp"])
                return true
            }
            if source == .claude, let custom = row["customTitle"] as? String { title = custom }
            if source == .claude, title == nil, let generated = row["aiTitle"] as? String { title = generated }

            let message: [String: Any]
            if source == .cursor {
                guard let value = row["message"] as? [String: Any] else { return true }
                var withRole = value
                withRole["role"] = row["role"]
                message = withRole
            } else if source == .codex {
                guard row["type"] as? String == "response_item", payload["type"] as? String == "message" else { return true }
                message = payload
            } else {
                guard ["user", "assistant"].contains(row["type"] as? String ?? ""),
                      row["isSidechain"] as? Bool != true, row["isMeta"] as? Bool != true,
                      row["isApiErrorMessage"] as? Bool != true,
                      let value = row["message"] as? [String: Any] else { return true }
                message = value
            }
            guard let role = message["role"] as? String, role == "user" || role == "assistant" else { return true }
            let accepted = ["input_text", "output_text", "text"]
            let content = message["content"] as? String
                ?? (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                    accepted.contains(block["type"] as? String ?? "") ? block["text"] as? String : nil
                }.joined(separator: "\n\n")
            var cleaned = content.replacingOccurrences(of: "(?s)<system-reminder>.*?</system-reminder>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if source == .cursor {
                if date == nil, let range = cleaned.range(of: "(?s)<timestamp>(.*?)</timestamp>", options: .regularExpression) {
                    let raw = cleaned[range].dropFirst(11).dropLast(12)
                    date = Self.cursorDate(String(raw))
                }
                cleaned = cleaned.replacingOccurrences(of: "(?s)<timestamp>.*?</timestamp>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "</?user_query>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let servicePrefixes = [
                "# AGENTS.md instructions for ", "<environment_context>", "<external_codex_apps_open_page>",
                "<subagent_notification>", "<user_shell_command>", "<local-command-", "<command-name>",
                "<command-message>", "[Request interrupted by user", "<task-notification>", "<teammate-message",
            ]
            guard !cleaned.isEmpty, !servicePrefixes.contains(where: { cleaned.hasPrefix($0) }) else { return true }
            if date == nil { date = parseDate(row["timestamp"]) }
            if role == "user", firstPrompt == nil { firstPrompt = cleaned }
            dialogue.append("## \(role == "user" ? "Пользователь" : source.rawValue)\n\n\(cleaned)")
            return true
        }

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty, try !consume(line) { return nil }
            }
        }
        if !buffer.isEmpty, try !consume(buffer) { return nil }

        if source == .cursor, date == nil {
            date = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? modificationDate(file)
        }
        guard let firstPrompt, let date else { return nil }
        let label = (title ?? firstPrompt).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Session(date: date, title: String(label.prefix(100)), dialogue: dialogue.joined(separator: "\n\n"))
    }

    /// "Friday, Nov 6, 2026, 1:02 AM (UTC+1)" -> Date.
    private static func cursorDate(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespaces)
        var offset = 0
        if let range = value.range(of: #"\(UTC([+-]\d+)(?::(\d+))?\)"#, options: .regularExpression) {
            let parts = value[range].dropFirst(4).dropLast().split(separator: ":")
            let hours = Int(parts.first ?? "0") ?? 0
            let minutes = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            offset = hours * 3600 + (hours < 0 ? -minutes : minutes) * 60
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
        return formatter.date(from: value)
    }

    // MARK: Antigravity (SQLite + schema-less protobuf)

    /// Reads only the fields known from real chats: step type 14 = user text (19.2),
    /// 15 = assistant text (20.1), time = 5.1.1 (epoch seconds).
    private func readAntigravity(_ file: URL) throws -> Session? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT step_type, step_payload FROM steps WHERE step_type IN (14, 15) ORDER BY idx", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var dialogue: [String] = []
        var date: Date?
        var firstPrompt: String?
        while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let payload = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            let fields = ProtoFields(payload)
            let isUser = sqlite3_column_int(statement, 0) == 14
            let text = isUser ? fields.message(19)?.string(2) : fields.message(20)?.string(1)
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if (text + "/").contains("/secretary/runs/") { return nil }
            if date == nil, let seconds = fields.message(5)?.message(1)?.varint(1), seconds > 0 {
                date = Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            if isUser, firstPrompt == nil { firstPrompt = text }
            dialogue.append("## \(isUser ? "Пользователь" : Source.antigravity.rawValue)\n\n\(text)")
        }
        guard let firstPrompt, let date else { return nil }
        let label = firstPrompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Session(date: date, title: String(label.prefix(100)), dialogue: dialogue.joined(separator: "\n\n"))
    }

    /// Minimal protobuf reader: first occurrence of a field number, no schema.
    private struct ProtoFields {
        private var entries: [(field: Int, varint: UInt64?, bytes: Data?)] = []

        init(_ data: Data) {
            let b = [UInt8](data)
            var i = 0
            func readVarint() -> UInt64? {
                var result: UInt64 = 0, shift: UInt64 = 0
                while i < b.count, shift < 64 {
                    let byte = b[i]; i += 1
                    result |= UInt64(byte & 0x7F) << shift
                    if byte < 0x80 { return result }
                    shift += 7
                }
                return nil
            }
            while i < b.count {
                guard let key = readVarint() else { break }
                let field = Int(key >> 3)
                switch key & 7 {
                case 0:
                    guard let v = readVarint() else { return }
                    entries.append((field, v, nil))
                case 1: i += 8
                case 5: i += 4
                case 2:
                    guard let length = readVarint(), length <= UInt64(b.count - i) else { return }
                    entries.append((field, nil, Data(b[i..<(i + Int(length))])))
                    i += Int(length)
                default: return
                }
            }
        }

        func message(_ field: Int) -> ProtoFields? {
            entries.first { $0.field == field && $0.bytes != nil }.flatMap { $0.bytes }.map(ProtoFields.init)
        }

        func string(_ field: Int) -> String? {
            entries.first { $0.field == field && $0.bytes != nil }.flatMap { $0.bytes }
                .flatMap { String(data: $0, encoding: .utf8) }
        }

        func varint(_ field: Int) -> UInt64? {
            entries.first { $0.field == field && $0.varint != nil }?.varint
        }
    }

    private func body(_ session: Session, source: Source, id: UUID) -> String {
        "# \(source.rawValue) — \(session.title)\n\n\(source.marker)\(id.uuidString.lowercased())\n\n\(session.dialogue)\n"
    }

    /// Replaces the note text only with a longer one: a cut or rotated log never shrinks a note.
    private func update(_ note: URL, with session: Session, source: Source, id: UUID) throws -> Bool {
        let body = Data(body(session, source: source, id: id).utf8)
        // Not URL resource values: they are cached on the stored URL.
        let size = (try? FileManager.default.attributesOfItem(atPath: note.path))?[.size] as? Int ?? Int.max
        guard body.count > size else { return false }
        try body.write(to: note, options: .atomic)
        return true
    }

    private func save(_ session: Session, source: Source, id: UUID) throws -> (file: URL, isNew: Bool) {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let identity = RecordingIdentity(id: id, createdAt: session.date)
        let name = identity.fileName(extension: "txt", idLength: 32, timeZone: .gmt)
        let file = recordings.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: file.path) else { return (file, false) }
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
            metadata[RecordingIdentity.metadataKey] = id.uuidString
            metadata[RecordingIdentity.createdAtMetadataKey] = ISO8601.string(from: session.date)
            metadata["processingStatus"] = LegacyProcessingStatus.completed.rawValue
            metadata["origin"] = ["source": "studio-session-import", "sessionId": id.uuidString]
            return true
        }
        try Data(body(session, source: source, id: id).utf8).write(to: file, options: .atomic)
        return (file, true)
    }
}
