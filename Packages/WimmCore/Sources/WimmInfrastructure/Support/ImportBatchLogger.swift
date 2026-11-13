import Foundation
import WimmDomain

/// Handles logging for a specific batch import session.
/// Logs are saved to ~/Library/Application Support/Wimm/logs/import_<timestamp>.log
public final class ImportBatchLogger {
    private let fileURL: URL
    private let startTime: Date

    public init() {
        self.startTime = Date()
        let timestamp = Int(startTime.timeIntervalSince1970)
        let logsDir = FileStore.baseDirectory().appendingPathComponent("logs", isDirectory: true)
        self.fileURL = logsDir.appendingPathComponent("import_\(timestamp).log")
        
        log("--- Batch Import Started at \(FileStore.fullDateTime(startTime)) ---")
    }

    public func log(_ message: String) {
        let timestamp = FileStore.timeStr(Date())
        let line = "[\(timestamp)] \(message)"
        FileStore.append(text: line, to: fileURL)
    }

    public func finalize() {
        let duration = Date().timeIntervalSince(startTime)
        log("--- Batch Import Finished. Total Duration: \(String(format: "%.2f", duration))s ---")
    }

    public var logURL: URL { fileURL }
}
