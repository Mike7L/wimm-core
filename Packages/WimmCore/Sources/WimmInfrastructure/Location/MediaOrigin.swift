import AVFoundation
import Foundation
import ImageIO
import WimmDomain

/// What an imported photo or video says about its own making: where and when
/// it was shot. Either may be missing; neither is guessed from the import.
public struct MediaOrigin: Sendable, Equatable {
    public var place: NoteLocation?
    public var shotAt: Date?

    public init(place: NoteLocation? = nil, shotAt: Date? = nil) {
        self.place = place
        self.shotAt = shotAt
    }

    /// A picked original, before it is re-encoded (that drops its EXIF).
    public static func read(imageData: Data) -> MediaOrigin {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return MediaOrigin() }
        return MediaOrigin(place: MediaLocation.read(imageSource: source), shotAt: shotAt(imageSource: source))
    }

    /// When the image file was shot (EXIF); nil for anything else.
    public static func shotAt(imageAt url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return shotAt(imageSource: source)
    }

    /// When the photo or video file was shot; nil for other files.
    public static func shotAt(fileAt url: URL) async -> Date? {
        if let date = shotAt(imageAt: url) { return date }
        guard FileStore.supportedVideoLocationExtensions.contains(url.pathExtension.lowercased()),
              let item = try? await AVURLAsset(url: url).load(.creationDate),
              let date = try? await item.load(.dateValue) else { return nil }
        return plausible(date)
    }

    static func shotAt(imageSource source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifDate(stamp, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    /// `DateTimeOriginal` with `OffsetTimeOriginal` when present (iPhone writes
    /// it), else read as local time.
    static func exifDate(_ stamp: String, offset: String?, now: Date = Date()) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            if let date = formatter.date(from: stamp + offset) { return plausible(date, now: now) }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: stamp).flatMap { plausible($0, now: now) }
    }

    /// A camera with an unset clock writes 1970 or a future date: not a
    /// shooting time, the note keeps its import date.
    static func plausible(_ date: Date, now: Date = Date()) -> Date? {
        let earliest = Date(timeIntervalSince1970: 631_152_000) // 1990-01-01
        return date >= earliest && date <= now.addingTimeInterval(86_400) ? date : nil
    }
}
