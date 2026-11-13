import Foundation

/// Device provenance for notes: which device created a recording or import.
/// Stored in the `.meta.json` sidecar under the "origin" key as
/// `{"platform": "macOS", "device": "Michas-MacBook-Pro"}` and carried across
/// devices by the regular sidecar sync. Absent key = unknown origin (legacy note).
public enum NoteOrigin {
    public static let metadataKey = "origin"
    public static let platformKey = "platform"
    public static let deviceKey = "device"

    #if os(macOS)
    public static let currentPlatform = "macOS"
    public static let currentDevice: String =
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #elseif os(iOS)
    public static let currentPlatform: String =
        hardwareModel.hasPrefix("iPad") ? "iPad" : "iPhone"
    public static let currentDevice: String = hardwareModel

    private static let hardwareModel: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        // The simulator reports the host CPU architecture.
        if machine == "arm64" || machine == "x86_64" {
            return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
                ?? "iPhone Simulator"
        }
        return machine
    }()
    #else
    public static let currentPlatform = "unknown"
    public static let currentDevice: String = ProcessInfo.processInfo.hostName
    #endif

    public static var metadataValue: [String: String] {
        [platformKey: currentPlatform, deviceKey: currentDevice]
    }

    /// Records the current device as the note's origin in its sidecar.
    /// Merges via upsert, so it is safe to call repeatedly.
    public static func stamp(_ recordingURL: URL) {
        FileStore.upsertMetadata(for: recordingURL, updates: [metadataKey: metadataValue])
    }

    /// Human-readable origin for a sidecar dict. Falls back to the filename
    /// heuristic for pre-origin notes: only live iPhone recordings ever used the
    /// "recording_" prefix, while "Wimm_" is shared by the macOS recorder and the
    /// iOS import paths — those stay unknown (nil).
    public static func displayString(metadata: [String: Any], fileName: String) -> String? {
        let origin = deviceDisplayString(metadata: metadata, fileName: fileName)
        let parts = [origin, RecordingInputDevice.displayName(metadata: metadata)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func deviceDisplayString(metadata: [String: Any], fileName: String) -> String? {
        if let dict = metadata[metadataKey] as? [String: Any] {
            let platform = (dict[platformKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let device = (dict[deviceKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch (platform, device) {
            case let (platform?, device?) where device != platform:
                return "\(platform) · \(device)"
            case let (platform?, _):
                return platform
            case let (nil, device?):
                return device
            case (nil, nil):
                break
            }
        }
        if fileName.hasPrefix("recording_") { return "iPhone" }
        return nil
    }
}
