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

@inline(__always) public func log(_ msg: String) {
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

@inline(__always) public func logDebug(_ msg: String) {
#if DEBUG
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
    _ = msg
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
