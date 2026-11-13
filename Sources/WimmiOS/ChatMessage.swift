import Foundation
import WimmDomain

public struct ChatMessage: Identifiable, Codable {
    public let id: UUID
    public let type: MessageType
    public let timestamp: Date
    public let content: Content
    public let location: Location?
    public let isSaved: Bool
    
    public init(id: UUID = UUID(), type: MessageType, timestamp: Date = Date(), content: Content, location: Location? = nil, isSaved: Bool = true) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.content = content
        self.location = location
        self.isSaved = isSaved
    }
    
    /// Creates a ChatMessage from a recording, setting isSaved based on metadata completion status.
    /// Use this when creating messages from recordings to properly track save status.
    /// - Parameters:
    ///   - recording: The Recording object
    ///   - metadata: Optional RecordingMetadata to check completion status
    /// - Returns: ChatMessage with appropriate isSaved status
    public static func from(recording: ChatMessageRecording, metadata: RecordingMetadata?) -> ChatMessage {
        let isSaved = metadata?.isComplete ?? true
        
        return ChatMessage(
            type: .recording(recording),
            timestamp: recording.createdAt,
            content: .audio(url: recording.url, duration: recording.duration),
            isSaved: isSaved
        )
    }
    
    public enum MessageType: Codable {
        case recording(ChatMessageRecording)
        case transcription(String)
        case system(String)
        
        // Custom Codable implementation might be needed if associated values are complex or need specific JSON structure,
        // but Swift's automatic synthesis usually handles enums with associated values fine unless specific format is required.
        // The prompt asks for "custom encoding/decoding for associated values and URL paths", so I will implement it manually.
        
        enum CodingKeys: String, CodingKey {
            case type
            case payload
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            
            switch type {
            case "recording":
                let recording = try container.decode(ChatMessageRecording.self, forKey: .payload)
                self = .recording(recording)
            case "transcription":
                let text = try container.decode(String.self, forKey: .payload)
                self = .transcription(text)
            case "system":
                let text = try container.decode(String.self, forKey: .payload)
                self = .system(text)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid MessageType")
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .recording(let recording):
                try container.encode("recording", forKey: .type)
                try container.encode(recording, forKey: .payload)
            case .transcription(let text):
                try container.encode("transcription", forKey: .type)
                try container.encode(text, forKey: .payload)
            case .system(let text):
                try container.encode("system", forKey: .type)
                try container.encode(text, forKey: .payload)
            }
        }
    }
    
    public enum Content: Codable {
        case audio(url: URL, duration: Double)
        case text(String)
        case mixed(audio: URL, text: String)
        
        enum CodingKeys: String, CodingKey {
            case type
            case url
            case duration
            case text
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            
            switch type {
            case "audio":
                let urlString = try container.decode(String.self, forKey: .url)
                let url = URL(fileURLWithPath: urlString) // Assuming local paths as per context
                let duration = try container.decode(Double.self, forKey: .duration)
                self = .audio(url: url, duration: duration)
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            case "mixed":
                let urlString = try container.decode(String.self, forKey: .url)
                let url = URL(fileURLWithPath: urlString)
                let text = try container.decode(String.self, forKey: .text)
                self = .mixed(audio: url, text: text)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid Content type")
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .audio(let url, let duration):
                try container.encode("audio", forKey: .type)
                try container.encode(url.path, forKey: .url) // Encode path for stability
                try container.encode(duration, forKey: .duration)
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .mixed(let url, let text):
                try container.encode("mixed", forKey: .type)
                try container.encode(url.path, forKey: .url)
                try container.encode(text, forKey: .text)
            }
        }
    }
    
    public struct Location: Codable {
        public let latitude: Double
        public let longitude: Double
        public let placeName: String?
        
        public init(latitude: Double, longitude: Double, placeName: String? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.placeName = placeName
        }
    }
}

// Since Recording is referenced in MessageType but not defined in the prompt, 
// I need to assume it exists or create a placeholder if it's external.
// However, looking at the prompt "Define MessageType enum with recording(Recording)..." implies Recording is a type.
// I'll create a simple struct for it within this file or assume it works if defined elsewhere. 
// Given "Recording" is likely a domain object (perhaps related to RecordingRepository), but here we are in WimmiOS.
// I will verify if Recording exists in the workspace first, but to strictly follow "Define MessageType enum with recording(Recording)", I'll assume it's a known type.
// BUT, if it's not imported, this code will fail.
// I'll check WimmCore references for a Recording type.
// If not found, I will define a stub or struct here to make it compile, or look for it.

// Wait, the user said "Implement the comments... verbatim".
// The comment says: "Define MessageType enum with recording(Recording), transcription(String), and system(String)."
// It doesn't explicitly say "Define Recording struct".
// But typically "Recording" refers to a captured audio session.
// I'll assume I need to define a simple Recording struct here if it's not available, or import it.
// Let's add a placeholder for Recording if logic dictates, but based on "verbatim", I should perhaps stick to what is requested.
// The prompt also says "Add the ticket-specified model...".
// I'll define a basic Recording struct to satisfy the requirement if it's not imported.

public struct ChatMessageRecording: Codable, Identifiable {
    public let id: UUID
    public let url: URL
    public let duration: Double
    public let createdAt: Date
    
    public init(id: UUID = UUID(), url: URL, duration: Double, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.duration = duration
        self.createdAt = createdAt
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case url
        case duration
        case createdAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let path = try container.decode(String.self, forKey: .url)
        url = URL(fileURLWithPath: path)
        duration = try container.decode(Double.self, forKey: .duration)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url.path, forKey: .url)
        try container.encode(duration, forKey: .duration)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
