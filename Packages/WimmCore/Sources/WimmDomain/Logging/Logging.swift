import Foundation
import os.log

// Central lightweight logging helpers.
// Keep formatting stable for easier log filtering, but also log to os.Logger for Console.app visibility.
private let _wimmLogger = Logger(subsystem: "app.wimm", category: "core")
private let _logJSONEnabled: Bool = {
    let env = ProcessInfo.processInfo.environment["WIMM_LOG_JSON"]?.lowercased()
    return env == "1" || env == "true"
}()

private enum LogLevel: String {
    case debug
    case info
}

private struct LogFormatters {
    // Every log line used to build a DateFormatter here. Formatting with a
    // configured DateFormatter is thread-safe.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601.stringWithFractionalSeconds(from: date)
    }
}

private func formatLogLine(level: LogLevel, subsystem: String, message: String, correlationId: String?) -> String {
    if _logJSONEnabled {
        var obj: [String: Any] = [
            "ts": LogFormatters.iso8601(Date()),
            "level": level.rawValue,
            "subsystem": subsystem,
            "message": message
        ]
        if let correlationId, !correlationId.isEmpty {
            obj["correlationId"] = correlationId
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let line = String(data: data, encoding: .utf8) {
            return line
        }
    }

    let time = LogFormatters.time(Date())
    if subsystem == "agent" {
        return "[\(time)] \(message)"
    }
    if level == .debug {
        return "[Wimm] DEBUG: \(message)"
    }
    return "[Wimm] \(time) | \(message)"
}

/// Backstop for plain `log()`/`logDebug()`: masks API-key-shaped strings
/// before they reach stderr or the unified log, the same patterns
/// `UnifiedEventLogger` already masks in event files. Keys should never be
/// logged in the first place; this only catches a slip (e.g. a URL or an
/// error body that still carries one).
public enum LogSecretMask {
    private static let geminiKeyRegex = try! NSRegularExpression(
        pattern: #"\bAIza[0-9A-Za-z\-_]{20,}"#)
    private static let openAIKeyRegex = try! NSRegularExpression(
        pattern: #"\bsk-[A-Za-z0-9\-_]{12,}"#)
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._\-+/=]+"#)

    public static func mask(_ value: String) -> String {
        // Cheap prefilter: nearly every log line has none of these.
        guard value.contains("AIza") || value.contains("sk-")
                || value.range(of: "bearer", options: .caseInsensitive) != nil
        else { return value }
        var out = value
        out = replace(geminiKeyRegex, with: "AIza<redacted>", in: out)
        out = replace(openAIKeyRegex, with: "sk-<redacted>", in: out)
        out = replace(bearerRegex, with: "Bearer <token>", in: out)
        return out
    }

    private static func replace(_ regex: NSRegularExpression, with template: String, in value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}

@inline(__always) public func log(_ rawMessage: String) {
    let msg = LogSecretMask.mask(rawMessage)
    let line = formatLogLine(level: .info, subsystem: "core", message: msg, correlationId: nil)
    // Console output for stable text logs
    fputs(line + "\n", stderr)
    UnifiedEventLogger.shared.logAppEvent(
        kind: "log",
        phase: "info",
        origin: "log",
        message: msg,
        source: "log"
    )
    // System logger (info level in release, debug in debug when using logDebug)
    _wimmLogger.info("\(msg, privacy: .public)")
}

@inline(__always) public func logDebug(_ rawMessage: String) {
#if DEBUG
    let msg = LogSecretMask.mask(rawMessage)
    let line = formatLogLine(level: .debug, subsystem: "core", message: msg, correlationId: nil)
    fputs(line + "\n", stderr)
    UnifiedEventLogger.shared.logAppEvent(
        kind: "log",
        phase: "debug",
        origin: "logDebug",
        message: msg,
        source: "logDebug"
    )
    _wimmLogger.debug("\(msg, privacy: .public)")
#else
    // No-op in release builds
    _ = rawMessage
#endif
}

// MARK: - Agent File Logging

public final class FileLogger: @unchecked Sendable {
    public static let shared = FileLogger()
    
    // Directory: ~/Library/Logs/Wimm/
    private let logDirectory: URL
    private let fileManager = FileManager.default
    
    private init() {
        if let envLogsDir = ProcessInfo.processInfo.environment["WIMM_LOGS_DIR"], !envLogsDir.isEmpty {
            self.logDirectory = URL(fileURLWithPath: envLogsDir)
        } else {
            let libraryDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
            self.logDirectory = libraryDir.appendingPathComponent("Logs").appendingPathComponent("Wimm")
        }
        
        try? fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
    }
    
    public func log(_ message: String) {
        UnifiedEventLogger.shared.logAgent(message: message, legacyLogDirectory: logDirectory)
    }
}

/// Helper for logging Agent activities to a persistent file
public func logAgent(_ message: String) {
    // Also print to console for debugging
    #if DEBUG
    log("[Agent] \(message)")
    #endif
    
    FileLogger.shared.log(message)
}
