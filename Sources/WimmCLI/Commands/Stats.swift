import ArgumentParser
import Foundation
import WimmInfrastructure
import WimmDomain

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show usage statistics and analytics"
    )

    func run() async throws {
        print("📊 WIMM Statistics\n")
        
        let fileRepository = FileRepository()
        let metadataRepository = MetadataRepository()
        let recordings = await fileRepository.recordings(order: .ascending, limit: nil)
        
        print("Files:")
        print("  Total Recordings: \(recordings.count)")
        
        var totalProcessed = 0
        var totalUnprocessed = 0
        var totalDuration: Double = 0
        
        // Use a simple progress indicator
        print("  Analyzing...", terminator: "")
        
        for (index, url) in recordings.enumerated() {
            if index % 50 == 0 { print(".", terminator: "") }
            
            let meta = await metadataRepository.metadata(for: url)
            if let _ = meta["duration"] as? Double {
                // If we have metadata, it's processed enough to have duration usually
                // But strictly "processed" usually means NoteCard exists
                if await metadataRepository.existingNoteCard(for: url) != nil {
                    totalProcessed += 1
                } else {
                     totalUnprocessed += 1
                }
            } else {
                totalUnprocessed += 1
            }
            
            // Try to extract duration from meta if possible, or skip to avoid heavy IO opening audio files
            if let duration = meta["duration"] as? Double {
                totalDuration += duration
            }
        }
        print(" Done.\n")
        
        print("Processing Status:")
        print("  ✅ Processed (NoteCards): \(totalProcessed)")
        print("  ⏳ Pending/Raw:           \(totalUnprocessed)")
        
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        let durationStr = formatter.string(from: totalDuration) ?? "\(totalDuration)s"
        
        print("\nVolume:")
        print("  ⏱️ Total Duration:        \(durationStr)")
        print("  🗓️ Average/Day (Est):     Too complex for quick stats") 
        
        // Unified event log storage (single source of truth)
        let logsDir = UnifiedEventLogger.eventsDirectoryURL()
        var logSize = 0
        var logCount = 0
        
        if let files = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            logCount = files.count
            logSize = files.reduce(0) { sum, url in
                let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
                return sum + (resources?.fileSize ?? 0)
            }
        }
        
        let sizeMB = Double(logSize) / 1024 / 1024
        print("\nSystem:")
        print("  🗂️ Unified Event Logs:    \(logCount) files (\(String(format: "%.1f", sizeMB)) MB)")
        print("  📁 Path:                  \(logsDir.path)")
        
    }
}
