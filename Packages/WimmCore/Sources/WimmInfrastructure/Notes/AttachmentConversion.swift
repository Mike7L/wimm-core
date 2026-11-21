import Foundation
import WimmDomain

/// Runs before the split (decided 2026-11-21, `docs/One_Note_One_Media_Decision_2026-11-09.md`):
/// an attachment of a type the library does not list becomes a file it does,
/// written next to the original, which stays where it is. SVG becomes PNG,
/// AMR/WebM voice becomes m4a, a saved web page, calendar or archive becomes
/// text; anything else, or a failed conversion, becomes a short text note
/// that says what the file was. The parent's entry then points at the new
/// file (`convertedFrom` keeps the old URL), so `AttachmentSplitMigration`
/// splits it like any other. Entries whose file is missing are left alone.
///
/// Dry-run unless `apply`. A rerun reuses a converted file that already
/// exists. Every sidecar write goes through `FileStore.mutateSidecar`.
public enum AttachmentConversion {
    public static let convertedFromKey = "convertedFrom"

    /// The tools that do the work; the CLI runs system tools (macOS only).
    public struct Converter: Sendable {
        public var svgToPNG: @Sendable (_ source: URL, _ output: URL) throws -> Void
        public var audioToM4A: @Sendable (_ source: URL, _ output: URL) throws -> Void
        public var htmlToText: @Sendable (_ source: URL) throws -> String
        public var zipListing: @Sendable (_ source: URL) throws -> String

        public init(svgToPNG: @escaping @Sendable (URL, URL) throws -> Void,
                    audioToM4A: @escaping @Sendable (URL, URL) throws -> Void,
                    htmlToText: @escaping @Sendable (URL) throws -> String,
                    zipListing: @escaping @Sendable (URL) throws -> String) {
            self.svgToPNG = svgToPNG
            self.audioToM4A = audioToM4A
            self.htmlToText = htmlToText
            self.zipListing = zipListing
        }
    }

    public enum Format: String, Codable, Sendable { case svg, amr, webm, html, ics, zip, unknown }

    public struct Item: Codable, Sendable, Equatable {
        public var parentSidecar: String
        public var attachmentID: String
        public var source: String
        public var format: Format
        /// png, m4a, txt
        public var output: String?
        /// convert, describe, reuse, failed
        public var action: String
        public var error: String?
    }

    public struct Report: Codable, Sendable {
        public var dryRun: Bool
        public var items: [Item] = []
        public var byFormat: [String: Int] = [:]
        public var byAction: [String: Int] = [:]
    }

    public static func run(library: URL = StoragePaths.baseDirectory(), apply: Bool,
                           converter: Converter) throws -> Report {
        let plan = try AttachmentSplitMigration.run(.init(apply: false, library: library))
        let recordings = library.appendingPathComponent("Recordings", isDirectory: true)
        var report = Report(dryRun: !apply)
        for parent in plan.parents {
            for entry in parent.items where entry.action == "unsupported" {
                let source = library.appendingPathComponent(entry.source)
                var item = Item(parentSidecar: parent.sidecar, attachmentID: entry.attachmentID,
                                source: entry.source, format: format(of: source), output: nil, action: "convert")
                do {
                    let output = try convert(source, format: item.format, relative: entry.source,
                                             apply: apply, converter: converter, action: &item.action)
                    item.output = AttachmentSplitMigration.relativePath(output, library: library)
                    if apply {
                        try repoint(sidecar: recordings.appendingPathComponent(parent.sidecar),
                                    attachmentID: entry.attachmentID, to: output, format: item.format)
                    }
                } catch {
                    item.action = "failed"
                    item.error = error.localizedDescription
                }
                report.byFormat[item.format.rawValue, default: 0] += 1
                report.byAction[item.action, default: 0] += 1
                report.items.append(item)
            }
        }
        return report
    }

    // MARK: - Conversion

    /// Read from the first bytes: Evernote often saved these without an extension.
    static func format(of url: URL) -> Format {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1024)) ?? Data()
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("#!AMR".utf8)) { return .amr }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .webm }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        let head = String(decoding: data, as: UTF8.self).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if head.hasPrefix("begin:vcalendar") { return .ics }
        if head.contains("<svg") { return .svg }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.contains("<html") { return .html }
        let ext = url.pathExtension.lowercased()
        return Format(rawValue: ext) ?? .unknown
    }

    private static func convert(_ source: URL, format: Format, relative: String, apply: Bool,
                                converter: Converter, action: inout String) throws -> URL {
        let fm = FileManager.default
        func sibling(_ ext: String) -> URL {
            source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + "." + ext)
        }
        func write(_ body: String, to url: URL) throws {
            if apply { try Data(body.utf8).write(to: url, options: .atomic) }
        }
        let header = "Вложение из старой заметки: \(describe(format)), файл `\(relative)` (оставлен на месте)."

        let media: (ext: String, run: (URL, URL) throws -> Void)?
        switch format {
        case .svg: media = ("png", converter.svgToPNG)
        case .amr, .webm: media = ("m4a", converter.audioToM4A)
        default: media = nil
        }
        if let media {
            let output = sibling(media.ext)
            if fm.fileExists(atPath: output.path) { action = "reuse"; return output }
            guard apply else { return output }
            do {
                try media.run(source, output)
                if fm.fileExists(atPath: output.path) { return output }
            } catch {}
            // A conversion that failed still leaves a note that says what was there.
            try? fm.removeItem(at: output)
            action = "describe"
            let text = sibling("txt")
            try write(header + "\n\nПреобразовать не удалось; размер \(size(of: source)).\n", to: text)
            return text
        }

        let output = sibling("txt")
        if fm.fileExists(atPath: output.path) { action = "reuse"; return output }
        switch format {
        case .html:
            let body = apply ? (try? converter.htmlToText(source)) ?? "" : ""
            if apply && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { action = "describe" }
            try write(header + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: output)
        case .ics:
            let body = apply ? String(decoding: try Data(contentsOf: source), as: UTF8.self) : ""
            try write(header + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: output)
        case .zip:
            let body = apply ? (try? converter.zipListing(source)) ?? "" : ""
            try write(header + "\n\nСодержимое архива:\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                      to: output)
        default:
            action = "describe"
            try write(header + "\n\nТип не распознан; размер \(size(of: source)).\n", to: output)
        }
        return output
    }

    private static func describe(_ format: Format) -> String {
        switch format {
        case .svg: return "векторная картинка SVG"
        case .amr: return "голосовая запись AMR"
        case .webm: return "запись WebM"
        case .html: return "сохранённая веб-страница"
        case .ics: return "событие календаря"
        case .zip: return "архив zip"
        case .unknown: return "файл неизвестного типа"
        }
    }

    private static func size(of url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The parent's entry now names the converted file; the old URL stays as provenance.
    private static func repoint(sidecar: URL, attachmentID: String, to output: URL, format: Format) throws {
        try FileStore.mutateSidecar(at: sidecar) { json in
            guard var list = json["attachments"] as? [[String: Any]],
                  let index = list.firstIndex(where: { ($0["id"] as? String)?.uppercased() == attachmentID.uppercased() })
            else { return false }
            var entry = list[index]
            if entry[convertedFromKey] == nil { entry[convertedFromKey] = entry["url"] }
            entry["url"] = output.absoluteString
            entry["type"] = output.pathExtension == "png" ? "image" : output.pathExtension == "m4a" ? "audio" : "text"
            list[index] = entry
            json["attachments"] = list
            return true
        }
    }
}
