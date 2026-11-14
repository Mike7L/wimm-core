import AVFoundation
import Foundation
import WimmDomain

/// Adds the keys `RecordingMetadata` cannot decode without (`recordingURL`,
/// `isComplete`, `lastSaved`, `duration`) to Voice Memos imports that never
/// went through `VoiceMemosMerge`: the imports with no earlier copy in the
/// library. Only missing keys are written, through `FileStore.mutateSidecar`;
/// a `duration` of 0 is replaced by the measured length. Dry run unless `apply`.
public enum VoiceMemosServiceFields {
    public struct NoteList: Codable, Sendable {
        public var notes: [String]
    }

    public enum Outcome: Sendable, Equatable {
        case wouldFill([String])
        case filled([String])
        case complete
        case skipped(String)
        case failed(String)
    }

    public struct Row: Sendable {
        public let note: String
        public let outcome: Outcome
        public let duration: Double?
    }

    public static func load(listAt url: URL) throws -> [String] {
        try JSONDecoder().decode(NoteList.self, from: Data(contentsOf: url)).notes
    }

    /// Length of an audio file in seconds, or nil if it cannot be opened.
    public static func measuredDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    public static func run(notes: [String], directory: URL, apply: Bool, limit: Int? = nil, now: Date = Date(),
                           measure: (URL) -> Double? = measuredDuration) -> [Row] {
        let stamp = ISO8601DateFormatter().string(from: now)
        var rows: [Row] = []
        var touched = 0
        for name in notes {
            let media = directory.appendingPathComponent(name)
            let sidecar = FileStore.metadataURL(forRecordingURL: media)
            guard FileManager.default.fileExists(atPath: media.path) else {
                rows.append(Row(note: name, outcome: .skipped("media file missing"), duration: nil)); continue
            }
            guard let data = try? Data(contentsOf: sidecar),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                rows.append(Row(note: name, outcome: .skipped("no readable sidecar"), duration: nil)); continue
            }
            guard dict["voiceMemos"] != nil else {
                rows.append(Row(note: name, outcome: .skipped("not a Voice Memos import"), duration: nil)); continue
            }
            let missing = missingKeys(dict)
            if missing.isEmpty { rows.append(Row(note: name, outcome: .complete, duration: nil)); continue }
            if let limit, touched >= limit { continue }
            let measured = missing.contains("duration") ? measure(media) : nil
            if missing.contains("duration"), (measured ?? 0) <= 0 {
                rows.append(Row(note: name, outcome: .skipped("duration not measurable"), duration: nil)); continue
            }
            touched += 1
            guard apply else { rows.append(Row(note: name, outcome: .wouldFill(missing), duration: measured)); continue }
            let relative = FileStore.relativePath(for: media)
            do {
                var written: [String] = []
                try FileStore.mutateSidecar(at: sidecar) { dict in
                    written = missingKeys(dict)
                    for key in written {
                        switch key {
                        case "recordingURL": dict[key] = relative
                        case "isComplete": dict[key] = true
                        case "lastSaved": dict[key] = stamp
                        case "duration": dict[key] = measured ?? 0
                        default: break
                        }
                    }
                    return !written.isEmpty
                }
                rows.append(Row(note: name, outcome: written.isEmpty ? .complete : .filled(written), duration: measured))
            } catch {
                rows.append(Row(note: name, outcome: .failed("\(error)"), duration: measured))
            }
        }
        return rows
    }

    static func missingKeys(_ dict: [String: Any]) -> [String] {
        var keys: [String] = []
        if dict["recordingURL"] == nil { keys.append("recordingURL") }
        if dict["isComplete"] == nil { keys.append("isComplete") }
        if dict["lastSaved"] == nil { keys.append("lastSaved") }
        let duration = (dict["duration"] as? NSNumber)?.doubleValue
        if duration == nil || duration == 0 { keys.append("duration") }
        return keys
    }
}
