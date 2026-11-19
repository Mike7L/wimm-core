import AVFoundation
import Foundation
import ImageIO
import WimmDomain

/// The place written inside an imported photo or video: where it was shot.
/// A file without one yields nil; the import place is never used instead.
public enum MediaLocation {
    public static func read(imageData: Data) -> NoteLocation? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return read(imageSource: source)
    }

    /// Photo EXIF GPS, or a video's location tag.
    public static func read(fileAt url: URL) async -> NoteLocation? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0,
           let location = read(imageSource: source) {
            return location
        }
        guard FileStore.supportedVideoLocationExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let metadata = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation) {
            if let text = try? await item.load(.stringValue), let location = parse(iso6709: text) {
                return location
            }
        }
        return nil
    }

    /// Reads the file's own place in the background and writes it into the
    /// note's sidecar. A file without one leaves the note without a place.
    public static func stampFromFile(for recordingURL: URL) {
        Task.detached(priority: .utility) {
            guard let location = await read(fileAt: recordingURL) else { return }
            NoteLocation.stamp(location, for: recordingURL)
        }
    }

    static func read(imageSource source: CGImageSource) -> NoteLocation? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return nil }
        return location(gps: gps)
    }

    static func location(gps: [CFString: Any]) -> NoteLocation? {
        guard var latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              var longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { latitude = -abs(latitude) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { longitude = -abs(longitude) }
        return NoteLocation(
            latitude: latitude,
            longitude: longitude,
            accuracy: (gps[kCGImagePropertyGPSHPositioningError] as? NSNumber)?.doubleValue,
            source: .media
        )
    }

    /// `+55.7558+037.6173+150.000/` (QuickTime / ISO 6709, decimal degrees).
    static func parse(iso6709 text: String) -> NoteLocation? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" {
                if !current.isEmpty, let value = Double(current) { numbers.append(value) }
                current = String(character)
            } else if character.isNumber || character == "." {
                current.append(character)
            } else {
                break
            }
        }
        if !current.isEmpty, let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2 else { return nil }
        return NoteLocation(latitude: numbers[0], longitude: numbers[1], source: .media)
    }
}

extension FileStore {
    static let supportedVideoLocationExtensions: Set<String> = ["mov", "mp4", "m4v"]
}
