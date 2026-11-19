import Foundation

/// Where a note was captured. Stored in the `.meta.json` sidecar under
/// `location` as `{"latitude": …, "longitude": …, "accuracy": …, "source":
/// "device", "fixedAt": "…"}` and carried across devices by the regular
/// sidecar sync. Absent key = unknown place; it is never guessed.
///
/// `source` says what the coordinates describe: `device` is where the
/// device was when the note was made, `media` is the place written inside
/// an imported photo or video (where it was shot, not where it was imported).
public struct NoteLocation: Equatable, Sendable {
    public enum Source: String, Sendable {
        case device
        case media
    }

    public static let metadataKey = "location"

    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy in metres, when known.
    public let accuracy: Double?
    public let source: Source
    /// When the position was measured, when known.
    public let fixedAt: Date?

    /// nil for coordinates outside the globe and for the 0,0 "no fix" value.
    public init?(latitude: Double, longitude: Double, accuracy: Double? = nil,
                 source: Source, fixedAt: Date? = nil) {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.source = source
        self.fixedAt = fixedAt
    }

    public init?(sidecarValue: Any?) {
        guard let dict = sidecarValue as? [String: Any],
              let latitude = (dict["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (dict["longitude"] as? NSNumber)?.doubleValue else { return nil }
        self.init(
            latitude: latitude,
            longitude: longitude,
            accuracy: (dict["accuracy"] as? NSNumber)?.doubleValue,
            source: (dict["source"] as? String).flatMap(Source.init(rawValue:)) ?? .device,
            fixedAt: (dict["fixedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        )
    }

    public var sidecarValue: [String: Any] {
        var dict: [String: Any] = [
            "latitude": Self.rounded(latitude),
            "longitude": Self.rounded(longitude),
            "source": source.rawValue,
        ]
        if let accuracy { dict["accuracy"] = accuracy.rounded() }
        if let fixedAt { dict["fixedAt"] = fixedAt.formatted(.iso8601) }
        return dict
    }

    /// `55.75580, 37.61730 (±25 m, device)`
    public var displayString: String {
        var details: [String] = []
        if let accuracy { details.append("±\(Int(accuracy.rounded())) m") }
        details.append(source == .media ? "from the media file" : "device")
        return String(format: "%.5f, %.5f", latitude, longitude) + " (\(details.joined(separator: ", ")))"
    }

    /// Writes the place into the note's sidecar. A place already there stays:
    /// the first one is the capture, a later call is not. Nothing is written
    /// once the note's file is gone (cancelled or trashed while the fix was
    /// still being taken), so no orphan sidecar appears.
    public static func stamp(_ location: NoteLocation, for recordingURL: URL) {
        guard FileManager.default.fileExists(atPath: recordingURL.path) else { return }
        try? FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: recordingURL)) { current in
            guard current[metadataKey] == nil else { return false }
            current[metadataKey] = location.sidecarValue
            return true
        }
    }

    /// Six decimals ≈ 0.1 m: more is noise and makes sidecars churn.
    private static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }
}
