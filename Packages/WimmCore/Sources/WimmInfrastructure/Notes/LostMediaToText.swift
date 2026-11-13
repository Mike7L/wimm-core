import Foundation
import WimmDomain

/// Notes whose media is gone but whose text survives in the sidecar become
/// plain `{base}.txt` notes with a one-line header
/// (`docs/Note_Content_Resolver_Design_2026-11-10.md`, "Migration: lost
/// notes to text"). Dry run by default. Apply only creates files: it never
/// writes a sidecar and never overwrites. The dry run is also the detector
/// for future losses: a non-empty candidate list means something was lost.
public enum LostMediaToText {
    public struct Candidate: Sendable, Equatable {
        public let base: String
        public let sidecar: URL
        public let durationSec: Double?
        public let words: Int
        public let header: String
        public let body: String
        public let links: Int

        /// The file `--apply` writes: header, blank line, the sidecar text.
        public var fileText: String { header + "\n\n" + body + "\n" }
    }

    /// A sidecar without its media that is not converted, and why.
    public struct Skipped: Sendable, Equatable {
        public enum Reason: String, Sendable, CaseIterable {
            /// `{base}_Attach_*` files exist: the one-note-one-media split owns it.
            case attachSession = "attach-session"
            /// Only `{base}_micro`/`_mini` audio survives: its audio exists.
            case derivedAudioOnly = "derived-audio-only"
            /// A `{parent}_screenN` preview's sidecar whose parent note is present:
            /// part of a living note, not a lost one.
            case previewOfPresentNote = "preview-of-present-note"
            /// Not a `Wimm_<date>` name: decided one by one.
            case nonWimmName = "non-wimm-name"
            /// Nothing to write (empty, or only a failure placeholder): proposed for Trash.
            case noText = "no-text"
        }
        public let base: String
        public let reason: Reason
        public let words: Int
    }

    public struct Report: Sendable {
        public var candidates: [Candidate] = []
        public var skipped: [Skipped] = []
        /// Apply only: files created, and rows skipped because a file appeared.
        public var created: [URL] = []
        public var refused: [String] = []
        public var sidecarsScanned = 0
        public var parseErrors: [String] = []
    }

    // MARK: - Scan

    /// Reads the library's `Recordings` folder (top level, as `FileRepository`
    /// lists it). Trash is a separate folder and never scanned.
    public static func scan(recordings: URL = FileStore.recordingsDirectory()) -> Report {
        let fm = FileManager.default
        var report = Report()
        let names = ((try? fm.contentsOfDirectory(atPath: recordings.path)) ?? []).filter { !$0.hasPrefix(".") }
        let files = names.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: recordings.appendingPathComponent(name).path, isDirectory: &isDir) && !isDir.boolValue
        }
        var mediaBases = Set<String>()
        var sessionFiles: [String: [String]] = [:]   // base prefix → `{base}_…` file names
        var sidecars: [(base: String, name: String)] = []
        for name in files {
            if let base = sidecarBase(name) {
                sidecars.append((base, name))
                continue
            }
            let base = (name as NSString).deletingPathExtension
            mediaBases.insert(base)
            for (i, ch) in base.enumerated() where ch == "_" {
                let prefix = String(base.prefix(i))
                sessionFiles[prefix, default: []].append(name)
            }
        }
        let links = linkCounts(recordings: recordings, files: files)

        for (base, name) in sidecars.sorted(by: { $0.base < $1.base }) {
            report.sidecarsScanned += 1
            guard !mediaBases.contains(base) else { continue }
            let url = recordings.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                report.parseErrors.append(name)
                continue
            }
            let session = sessionFiles[base] ?? []
            let body = text(of: url, sidecar: sidecar)
            let words = body.map(wordCount) ?? 0
            func skip(_ reason: Skipped.Reason) { report.skipped.append(Skipped(base: base, reason: reason, words: words)) }
            if session.contains(where: { $0.hasPrefix(base + "_Attach_") }) { skip(.attachSession); continue }
            if session.contains(where: { FileStore.isDerivedAudioFile(recordings.appendingPathComponent($0)) }) {
                skip(.derivedAudioOnly); continue
            }
            if let parent = FileStore.previewImageSessionBase(recordings.appendingPathComponent(base + ".heic")),
               parent != base, mediaBases.contains(parent) {
                skip(.previewOfPresentNote); continue
            }
            let anchor = recordings.appendingPathComponent(base + ".txt")
            guard base.hasPrefix("Wimm_"), let recorded = FileStore.recordingDateFromFileName(anchor) else {
                skip(.nonWimmName); continue
            }
            guard let body else { skip(.noText); continue }
            let duration = durationSec(sidecar)
            report.candidates.append(Candidate(
                base: base, sidecar: url, durationSec: duration, words: words,
                header: header(durationSec: duration, recorded: recorded), body: body, links: links[base] ?? 0))
        }
        return report
    }

    // MARK: - Apply

    /// Creates `{base}.txt` for each candidate and nothing else. A row is
    /// refused when any file of that base (other than its sidecar) exists now.
    public static func apply(_ report: Report, recordings: URL = FileStore.recordingsDirectory()) -> Report {
        var out = report
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: recordings.path)) ?? []
        for candidate in report.candidates {
            let taken = names.contains { name in
                sidecarBase(name) == nil && (name as NSString).deletingPathExtension == candidate.base
            }
            let target = recordings.appendingPathComponent(candidate.base + ".txt")
            // `.withoutOverwriting` is O_EXCL: a file that appears after the check still wins.
            guard !taken,
                  (try? Data(candidate.fileText.utf8).write(to: target, options: .withoutOverwriting)) != nil else {
                out.refused.append(candidate.base)
                continue
            }
            // Dates of the new file only: created = recorded, modified = the sidecar's,
            // so the note keeps its "updated" time and does not look changed to a pass.
            var dates: [FileAttributeKey: Any] = [:]
            if let recorded = FileStore.recordingDateFromFileName(target) { dates[.creationDate] = recorded }
            if let modified = (try? candidate.sidecar.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                // Whole seconds, rounded down: never later than the sidecar, whatever precision the volume keeps.
                dates[.modificationDate] = Date(timeIntervalSince1970: modified.timeIntervalSince1970.rounded(.down))
            }
            try? fm.setAttributes(dates, ofItemAtPath: target.path)
            out.created.append(target)
        }
        return out
    }

    // MARK: - Rules

    static func sidecarBase(_ name: String) -> String? {
        for suffix in [".meta.json", ".metadata.json"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// The resolver's rules for a note without media: transcript, legacy
    /// string, then `document.text` (a sidecar path reads as a document
    /// anchor). A failure placeholder is no text.
    static func text(of sidecarURL: URL, sidecar: [String: Any]) -> String? {
        guard let body = NoteContent.resolve(anchor: sidecarURL, sidecar: sidecar, typedFileText: nil).body,
              !isPlaceholder(body) else { return nil }
        return body
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower == "[[no_speech]]" { return true }
        return ["no speech detected", "transcription failed", "import transcription failed", "no text recognized"]
            .contains { lower == $0 || lower.hasPrefix($0 + " (") }
    }

    static func durationSec(_ sidecar: [String: Any]) -> Double? {
        let transcription = sidecar["transcription"] as? [String: Any]
        let raw = transcription?["audioDurationSec"] ?? sidecar["audioDurationSec"] ?? sidecar["durationSec"]
        guard let value = (raw as? Double) ?? (raw as? NSNumber)?.doubleValue, value > 0 else { return nil }
        return value
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// `[Расшифровка утраченной аудиозаписи · 6 мин 52 с · записано 2026-01-14 09:12]`,
    /// or `[Текст утраченного файла · записано …]` when the duration is unknown.
    public static func header(durationSec: Double?, recorded: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let when = "записано " + formatter.string(from: recorded)
        guard let durationSec else { return "[Текст утраченного файла · \(when)]" }
        return "[Расшифровка утраченной аудиозаписи · \(duration(durationSec)) · \(when)]"
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return s > 0 ? "\(m) мин \(s) с" : "\(m) мин" }
        return "\(s) с"
    }

    /// `[[target]]` / `[[target|alias]]` / `[[target#heading]]` in text notes and
    /// sidecars, counted by stem (links match by file name without extension).
    static func linkCounts(recordings: URL, files: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let scanned = files.filter { name in
            sidecarBase(name) != nil || ["txt", "md", "markdown"].contains((name as NSString).pathExtension.lowercased())
        }
        for name in scanned {
            guard let data = try? Data(contentsOf: recordings.appendingPathComponent(name)),
                  let text = String(data: data, encoding: .utf8), text.contains("[[") else { continue }
            var rest = text[...]
            while let open = rest.range(of: "[[") {
                rest = rest[open.upperBound...]
                guard let close = rest.range(of: "]]") else { break }
                var target = String(rest[..<close.lowerBound])
                rest = rest[close.upperBound...]
                if let cut = target.firstIndex(where: { $0 == "|" || $0 == "#" }) { target = String(target[..<cut]) }
                target = (target as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
                let stem = (target as NSString).deletingPathExtension
                let key = ["txt", "md", "markdown", "m4a", "caf", "wav", "mp3", "aac"]
                    .contains((target as NSString).pathExtension.lowercased()) ? stem : target
                guard !key.isEmpty, key.count < 200 else { continue }
                counts[key, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Report

    public static func markdown(_ report: Report, applied: Bool, library: URL, generated: Date = Date()) -> String {
        let iso = ISO8601DateFormatter().string(from: generated)
        var lines = ["# lost-to-text \(applied ? "APPLY" : "dry run") \(iso)", "",
                     "Library: `\(library.path)`", "",
                     "Sidecars scanned: \(report.sidecarsScanned); parse errors: \(report.parseErrors.count)", ""]
        let c = report.candidates
        let words = c.reduce(0) { $0 + $1.words }
        let known = c.filter { $0.durationSec != nil }
        let hours = known.reduce(0.0) { $0 + ($1.durationSec ?? 0) } / 3600
        lines += ["## Candidates (would become `{base}.txt`)", "",
                  "\(c.count) notes, \(words) words; \(known.count) with a known duration (\(String(format: "%.1f", hours)) h); "
                    + "\(c.filter { $0.links > 0 }.count) with incoming `[[links]]`.", "",
                  "| base | duration | words | links | header |", "|---|---|---|---|---|"]
        for row in c {
            lines.append("| \(row.base) | \(row.durationSec.map { duration($0) } ?? "-") | \(row.words) | \(row.links) | \(row.header) |")
        }
        lines.append("")
        for reason in Skipped.Reason.allCases {
            let rows = report.skipped.filter { $0.reason == reason }
            lines += ["## Not converted: \(reason.rawValue) (\(rows.count))", ""]
            lines += rows.map { "- \($0.base) (\($0.words) words)" }
            lines.append("")
        }
        if !report.parseErrors.isEmpty {
            lines += ["## Unreadable sidecars (\(report.parseErrors.count))", ""] + report.parseErrors.map { "- \($0)" } + [""]
        }
        if applied {
            lines += ["## Created (\(report.created.count)) — undo = delete these files", ""]
                + report.created.map { "- \($0.path)" } + [""]
            lines += ["## Refused: a file with that base exists (\(report.refused.count))", ""]
                + report.refused.map { "- \($0)" } + [""]
        }
        return lines.joined(separator: "\n")
    }
}
