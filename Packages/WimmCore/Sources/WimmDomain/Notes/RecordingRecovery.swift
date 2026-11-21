import Foundation

/// Recordings the iPhone did not finish (the app stopped mid-note): their
/// `.metadata.json` still says `isComplete == false`. Every audio original is
/// checked, not the note list (which groups files into notes).
public enum RecordingRecovery {
    public static func incompleteRecordings(fileManager: FileManager = .default) -> [URL] {
        let directory = FileStore.recordingsDirectory()
        let audio = ((try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { FileStore.isAudioFile($0) && !FileStore.isDerivedAudioFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return audio.filter { url in
            guard fileManager.fileExists(atPath: RecordingMetadata.metadataURL(for: url).path) else { return false }
            do {
                return !(try RecordingMetadata.load(for: url).isComplete)
            } catch {
                log("RecordingRecovery: failed to load metadata for \(url.lastPathComponent): \(error)")
                return false
            }
        }
    }

    public static func markAsComplete(_ url: URL) throws {
        var metadata = try RecordingMetadata.load(for: url)
        metadata.isComplete = true
        metadata.lastSaved = Date()
        try metadata.save()
    }
}
