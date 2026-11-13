import Foundation

/// The microphone actually selected by the recording route at capture start.
/// Separate from `origin`: a Mac may record through a Bluetooth or USB mic.
public struct RecordingInputDevice: Equatable, Sendable {
    public static let metadataKey = "audioInput"
    public let name: String
    public let transport: String

    public init(name: String, transport: String) {
        self.name = name
        self.transport = transport
    }

    public func stamp(_ recordingURL: URL) {
        FileStore.upsertMetadata(for: recordingURL, updates: [
            Self.metadataKey: ["name": name, "transport": transport]
        ])
    }

    public static func displayName(metadata: [String: Any]) -> String? {
        guard let input = metadata[metadataKey] as? [String: Any],
              let name = input["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}
