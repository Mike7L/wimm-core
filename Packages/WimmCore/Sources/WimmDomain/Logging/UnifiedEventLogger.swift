import Foundation

public struct UnifiedEventRecord: Codable, Sendable {
    public let v: Int
    public let event_id: String
    public let timestamp: Date
    public let kind: String
    public let phase: String?
    public let correlation_id: String?
    public let model: String?
    public let provider: String?
    public let origin: String?
    public let attributes: [String: String]?
    public let is_streaming: Bool?
    public let system: String?
    public let user: String?
    public let response: String?
    public let error: String?
    public let message: String?
    public let source: String?
}

public final class UnifiedEventLogger: @unchecked Sendable {
    public static let shared = UnifiedEventLogger()

    private let queue = DispatchQueue(label: "com.wimm.unified_event_logger.write", qos: .utility)
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter
    private let retentionDays: Int
    private let maxFileBytes: Int64
    private let cleanupInterval: TimeInterval = 60 * 60
    private var lastCleanupAt: Date = .distantPast

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#)
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._\-+/=]+\b"#)
    private static let openAIKeyRegex = try! NSRegularExpression(
        pattern: #"\bsk-[A-Za-z0-9]{12,}\b"#)
    private static let geminiKeyRegex = try! NSRegularExpression(
        pattern: #"\bAIza[0-9A-Za-z\-_]{20,}\b"#)
    private static let phoneCandidateRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)\+?\d[\d\-\s().:]{6,}\d(?!\d)"#)
    private static let eventFileRegex = try! NSRegularExpression(
        pattern: #"^events_(\d{4}-\d{2}-\d{2})(?:\.\d+)?\.jsonl$"#)

    private init() {
        let days = ProcessInfo.processInfo.environment["WIMM_EVENT_LOG_RETENTION_DAYS"]
            .flatMap(Int.init) ?? 30
        self.retentionDays = max(1, days)

        let maxMb = ProcessInfo.processInfo.environment["WIMM_EVENT_LOG_MAX_FILE_MB"]
            .flatMap(Int64.init) ?? 20
        self.maxFileBytes = max(1, maxMb) * 1024 * 1024

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]

        self.dayFormatter = DateFormatter()
        self.dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    public static func eventsDirectoryURL() -> URL {
        StoragePaths.baseDirectory()
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    public func logAgent(message: String, legacyLogDirectory: URL? = nil) {
        let now = Date()
        let record = UnifiedEventRecord(
            v: 1,
            event_id: UUID().uuidString.lowercased(),
            timestamp: now,
            kind: "agent",
            phase: nil,
            correlation_id: nil,
            model: nil,
            provider: nil,
            origin: nil,
            attributes: nil,
            is_streaming: nil,
            system: nil,
            user: nil,
            response: nil,
            error: nil,
            message: sanitizeText(message, maxLength: 16_000),
            source: "FileLogger"
        )
        enqueue(
            record: record,
            legacyAgentMessage: record.message ?? message,
            legacyLogDirectory: legacyLogDirectory
        )
    }

    public func logLLM(
        phase: String,
        correlationId: UUID,
        model: String,
        provider: String,
        origin: String?,
        attributes: [String: String],
        isStreaming: Bool,
        system: String?,
        user: String?,
        response: String?,
        error: String?,
        source: String
    ) {
        let record = UnifiedEventRecord(
            v: 1,
            event_id: UUID().uuidString.lowercased(),
            timestamp: Date(),
            kind: "llm",
            phase: phase,
            correlation_id: correlationId.uuidString,
            model: sanitizeText(model, maxLength: 128),
            provider: sanitizeText(provider, maxLength: 64),
            origin: sanitizeOptionalText(origin, maxLength: 256),
            attributes: sanitizeAttributes(attributes),
            is_streaming: isStreaming,
            system: sanitizeOptionalText(system, maxLength: 8_000),
            user: sanitizeOptionalText(user, maxLength: 16_000),
            response: sanitizeOptionalText(response, maxLength: 16_000),
            error: sanitizeOptionalText(error, maxLength: 4_000),
            message: nil,
            source: source
        )
        enqueue(record: record)
    }

    public func logAppEvent(
        kind: String,
        phase: String?,
        origin: String?,
        message: String?,
        attributes: [String: String] = [:],
        error: String? = nil,
        source: String
    ) {
        let record = UnifiedEventRecord(
            v: 1,
            event_id: UUID().uuidString.lowercased(),
            timestamp: Date(),
            kind: sanitizeText(kind, maxLength: 64),
            phase: sanitizeOptionalText(phase, maxLength: 64),
            correlation_id: nil,
            model: nil,
            provider: nil,
            origin: sanitizeOptionalText(origin, maxLength: 256),
            attributes: sanitizeAttributes(attributes),
            is_streaming: nil,
            system: nil,
            user: nil,
            response: nil,
            error: sanitizeOptionalText(error, maxLength: 4_000),
            message: sanitizeOptionalText(message, maxLength: 16_000),
            source: sanitizeText(source, maxLength: 128)
        )
        enqueue(record: record)
    }

    private func enqueue(record: UnifiedEventRecord, legacyAgentMessage: String? = nil, legacyLogDirectory: URL? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.performCleanupIfNeeded(now: record.timestamp)
            self.write(record)
            if let legacyAgentMessage, let legacyLogDirectory {
                self.writeLegacyAgentLine(message: legacyAgentMessage, timestamp: record.timestamp, logDirectory: legacyLogDirectory)
            }
        }
    }

    private func write(_ record: UnifiedEventRecord) {
        let dir = Self.eventsDirectoryURL()
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = targetFileURL(for: record.timestamp, in: dir)
            let data = try encoder.encode(record)
            appendLine(data: data, to: fileURL)
        } catch {
            fputs("[Wimm] UnifiedEventLogger write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func appendLine(data: Data, to fileURL: URL) {
        var line = data
        line.append(0x0A)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: line)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line)
    }

    private func targetFileURL(for date: Date, in dir: URL) -> URL {
        let day = dayFormatter.string(from: date)
        let baseName = "events_\(day)"
        let baseURL = dir.appendingPathComponent("\(baseName).jsonl")
        if fileSize(baseURL) < maxFileBytes { return baseURL }

        for index in 1...99 {
            let candidate = dir.appendingPathComponent("\(baseName).\(index).jsonl")
            if fileSize(candidate) < maxFileBytes {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(baseName).99.jsonl")
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else {
            return 0
        }
        return n.int64Value
    }

    private func performCleanupIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else { return }
        lastCleanupAt = now

        let dir = Self.eventsDirectoryURL()
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let cutoffDay = Calendar.current.startOfDay(for: cutoff)

        for file in files {
            let name = file.lastPathComponent
            let range = NSRange(location: 0, length: name.utf16.count)
            guard let match = Self.eventFileRegex.firstMatch(in: name, options: [], range: range),
                  let dayRange = Range(match.range(at: 1), in: name) else {
                continue
            }
            let dayString = String(name[dayRange])
            guard let dayDate = dayFormatter.date(from: dayString) else { continue }
            if dayDate < cutoffDay {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func writeLegacyAgentLine(message: String, timestamp: Date, logDirectory: URL) {
        let day = dayFormatter.string(from: timestamp)
        let fileURL = logDirectory.appendingPathComponent("Agent-\(day).log")
        let line = "[\(legacyTime(timestamp))] \(message)\n"
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    // Called for every event; used to build a fresh DateFormatter each time.
    private static let legacyTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func legacyTime(_ date: Date) -> String {
        Self.legacyTimeFormatter.string(from: date)
    }

    private func sanitizeOptionalText(_ value: String?, maxLength: Int) -> String? {
        guard let value, !value.isEmpty else { return value }
        return sanitizeText(value, maxLength: maxLength)
    }

    private func sanitizeAttributes(_ attrs: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(attrs.count)
        for (k, v) in attrs {
            if shouldRedactKey(k) {
                out[k] = "<redacted>"
            } else {
                out[k] = sanitizeText(v, maxLength: 512)
            }
        }
        return out
    }

    /// Usage counters are plain integers, but their names contain "token" and
    /// would otherwise be swallowed by the secret filter below. They are listed
    /// explicitly rather than pattern-matched, so a future `api_token` attribute
    /// still gets redacted.
    private static let usageCounterKeys: Set<String> = [
        "tokens_in", "tokens_out", "tokens_total", "tokens_cached_in", "tokens_audio",
        "tokens_thoughts",
    ]

    private func shouldRedactKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if Self.usageCounterKeys.contains(k) { return false }
        return k.contains("key") || k.contains("token") || k.contains("secret")
            || k.contains("password") || k.contains("cookie") || k.contains("authorization")
    }

    private func sanitizeText(_ value: String, maxLength: Int) -> String {
        var out = value
        out = applying(regex: Self.emailRegex, replacement: "<email>", in: out)
        out = applying(regex: Self.bearerRegex, replacement: "Bearer <token>", in: out)
        out = applying(regex: Self.openAIKeyRegex, replacement: "sk-<redacted>", in: out)
        out = applying(regex: Self.geminiKeyRegex, replacement: "AIza<redacted>", in: out)
        out = redactPhoneLike(in: out)
        if out.count > maxLength {
            out = String(out.prefix(maxLength)) + "…<truncated>"
        }
        return out
    }

    private func applying(regex: NSRegularExpression, replacement: String, in value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }

    private func redactPhoneLike(in value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = Self.phoneCandidateRegex.matches(in: value, options: [], range: range)
        guard !matches.isEmpty else { return value }

        let output = NSMutableString(string: value)
        for match in matches.reversed() {
            let candidate = output.substring(with: match.range)
            let digits = candidate.filter(\.isNumber)
            guard digits.count >= 10, digits.count <= 15 else { continue }
            guard !looksLikeDateOrTime(candidate) else { continue }
            output.replaceCharacters(in: match.range, with: "<phone>")
        }
        return String(output)
    }

    private func looksLikeDateOrTime(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?$"#,
            #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$"#,
            #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\s+\d{1,2}:\d{2}(?::\d{2})?$"#,
            #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\s+\d{1,2}:\d{2}(?::\d{2})?\s*[+-]\d{4}$"#
        ]
        for p in patterns {
            if s.range(of: p, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
