import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export notes to an LLM-friendly bundle")

    @Option(name: .shortAndLong, help: "Output directory path")
    var output: String?

    @Option(name: .shortAndLong, help: "Filter by month (YYYY-MM)")
    var month: String?

    @Flag(name: .shortAndLong, help: "Include unprocessed (raw) notes")
    var includeUnprocessed: Bool = false
    
    @Flag(name: .long, help: "Export as a single Markdown file (no bundle)")
    var singleFile: Bool = false

    func run() async throws {
        let fileRepo = FileRepository()
        var recordings = await fileRepo.recordings(order: .ascending)
        
        let targetMonth: String
        if let monthStr = month {
            targetMonth = monthStr
        } else {
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            targetMonth = formatter.string(from: now)
        }
        
        recordings = filter(recordings, byMonth: targetMonth)
        
        if recordings.isEmpty {
            print("No notes found for \(targetMonth).")
            return
        }
        
        print("🔍 Found \(recordings.count) notes for \(targetMonth). Starting export...")
        
        let exporter = LLMBundleExporter.shared
        var options = LLMBundleExporter.ExportOptions()
        options.filterUnprocessed = !includeUnprocessed
        
        // Single file mode implies no asset copying (as requested)
        if singleFile {
            let markdown = await exporter.generateMarkdownChronicle(for: recordings, options: options)
            let defaultName = "Wimm_Stream_\(targetMonth).md"
            let finalURL: URL
            
            if let outPath = output {
                if outPath.hasSuffix(".md") || outPath.hasSuffix(".markdown") {
                    finalURL = URL(fileURLWithPath: outPath)
                } else {
                    let dirURL = URL(fileURLWithPath: outPath)
                    // Create dir if needed
                    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    finalURL = dirURL.appendingPathComponent(defaultName)
                }
            } else {
                let fm = FileManager.default
                let baseDir = fm.currentDirectoryPath == "/" ? fm.temporaryDirectory : URL(fileURLWithPath: fm.currentDirectoryPath)
                finalURL = baseDir.appendingPathComponent(defaultName)
            }
            
            try markdown.write(to: finalURL, atomically: true, encoding: .utf8)
            print("✅ Export successful!")
            print("📄 File: \(finalURL.path)")
            print("🔢 Entries: \(markdown.filter { $0 == "\n" }.count)") // Crude line count, but helps
            return
        }
        
        let fm = FileManager.default
        let baseDir = output != nil ? URL(fileURLWithPath: output!) : fm.temporaryDirectory
        let bundleName = "Wimm_Export_\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))"
        let destination = baseDir.appendingPathComponent(bundleName)
        
        do {
            let bundleURL = try await exporter.exportBundle(for: recordings, to: destination, options: options)
            print("✅ Export successful!")
            print("📦 Bundle: \(bundleURL.path)")
            print("📖 Chronicle: \(bundleURL.appendingPathComponent("chronicle.md").path)")
        } catch {
            print("❌ Export failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func filter(_ urls: [URL], byMonth monthStr: String) -> [URL] {
        // Expected format YYYY-MM
        let components = monthStr.split(separator: "-")
        guard components.count == 2, 
              let year = Int(components[0]), 
              let month = Int(components[1]) else {
            print("⚠️ Invalid month format. Use YYYY-MM. Ignoring filter.")
            return urls
        }
        
        print("📅 Filtering for \(monthStr)...")
        let calendar = Calendar.current
        
        var matchCount = 0
        let filtered = urls.filter { url in
            guard let date = getEffectiveDate(for: url) else { return false }
            
            let dYear = calendar.component(.year, from: date)
            let dMonth = calendar.component(.month, from: date)
            
            let match = dYear == year && dMonth == month
            if match { matchCount += 1 }
            return match
        }
        
        print("✅ Found \(matchCount) matches via metadata/filename/attributes")
        return filtered
    }

    private func getEffectiveDate(for url: URL) -> Date? {
        // 1. Try Filename (Wimm_YYYY-MM-DD_...)
        let filename = url.lastPathComponent
        if filename.hasPrefix("Wimm_") {
             let parts = filename.split(separator: "_")
             if parts.count >= 2 {
                 let datePart = String(parts[1]) // 2026-02-01
                 let formatter = DateFormatter()
                 formatter.dateFormat = "yyyy-MM-dd"
                 if let date = formatter.date(from: datePart) {
                     return date
                 }
             }
        }
        
        // 2. Try Metadata Sidecar
        // Sidecar is usually file.meta.json (replacing extension)
        let metaURL = url.deletingPathExtension().appendingPathExtension("meta.json")
        
        // Attempt to read just enough to get the timestamp, using RecordingMetadata structure or raw JSON
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            // Try "timestamp" field (standard RecordingMetadata)
            if let timestampStr = json["timestamp"] as? String {
                // ISO8601 parsing
                if let date = ISO8601.parseEither(timestampStr) {
                    return date
                }
            }
        }
        
        // 3. Fallback to file creation date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let creationDate = attrs[.creationDate] as? Date {
            return creationDate
        }
        
        return nil
    }
}
