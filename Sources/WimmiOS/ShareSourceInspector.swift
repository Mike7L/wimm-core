#if os(iOS)
import AVFoundation
import Foundation
import ImageIO
import WimmDomain
import PDFKit

/// Reads what a shared file says about itself: when it was originally made
/// and, where the format records it, which app or camera made it. iOS tells a
/// share extension nothing about the app that shared an item, so this is the
/// only honest source of "which app" there is — Voice Memos stamps its
/// encoder, a camera writes EXIF, a PDF names its creator.
enum ShareSourceInspector {
    struct Findings {
        var date: Date?
        var app: String?
    }

    static func inspect(_ url: URL) async -> Findings {
        let ext = url.pathExtension.lowercased()
        if FileStore.supportedAudioExtensions.contains(ext) {
            return await audio(url)
        }
        if ext == "pdf" {
            return pdf(url)
        }
        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) {
            return image(url)
        }
        return Findings()
    }

    // MARK: - Audio

    private static func audio(_ url: URL) async -> Findings {
        let asset = AVURLAsset(url: url)
        var findings = Findings()
        if let item = try? await asset.load(.creationDate) {
            if let date = try? await item.load(.dateValue) {
                findings.date = date
            } else if let string = try? await item.load(.stringValue) {
                findings.date = parseLooseDate(string)
            }
        }
        if let items = try? await asset.load(.metadata) {
            for item in items where findings.app == nil {
                let key = item.identifier
                guard key == .commonIdentifierSoftware
                    || key == .iTunesMetadataEncodingTool
                    || key == .quickTimeMetadataSoftware
                else { continue }
                if let value = try? await item.load(.stringValue) {
                    findings.app = appName(fromSoftware: value)
                }
            }
        }
        return findings
    }

    // MARK: - Image

    private static func image(_ url: URL) -> Findings {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return Findings() }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var findings = Findings()
        if let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            findings.date = exifDate(stamp, offset: offset)
        }
        // The camera is the more telling source for a photo; "Software" on an
        // iPhone shot is just the iOS version.
        if let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces),
           !model.isEmpty {
            findings.app = model
        } else if let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            findings.app = appName(fromSoftware: software)
        }
        return findings
    }

    // MARK: - PDF

    private static func pdf(_ url: URL) -> Findings {
        guard let attributes = PDFDocument(url: url)?.documentAttributes else { return Findings() }
        var findings = Findings()
        findings.date = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String
        let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String
        findings.app = (creator ?? producer).flatMap(appName(fromSoftware:))
        return findings
    }

    // MARK: - Helpers

    /// "com.apple.VoiceMemos (iPhone Version 18.1 (Build 22B83))" → "Voice Memos".
    /// Anything else is kept as written, without trailing version noise.
    static func appName(fromSoftware raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let known: [(prefix: String, name: String)] = [
            ("com.apple.VoiceMemos", L10n.iOS.Recording.sourceVoiceMemos),
            ("com.apple.mobilenotes", "Notes"),
        ]
        if let match = known.first(where: { trimmed.hasPrefix($0.prefix) }) {
            return match.name
        }
        // Bare OS version strings ("18.1") say nothing about the source.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        let head = trimmed.components(separatedBy: " (").first ?? trimmed
        return String(head.prefix(60))
    }

    private static func exifDate(_ stamp: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, let zone = timeZone(fromOffset: offset) {
            formatter.timeZone = zone
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: stamp)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":")
        guard let sign = offset.first, sign == "+" || sign == "-",
              parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1])
        else { return nil }
        let seconds = (h * 3600 + m * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func parseLooseDate(_ string: String) -> Date? {
        if let date = WimmDomain.ISO8601.parseEither(string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
#endif
