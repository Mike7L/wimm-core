import Foundation

/// Unified helper for determining attachment types across the app
public enum AttachmentTypeHelper {
    
    /// Supported attachment types
    public enum AttachmentType: String, Codable {
        case image
        case pdf
        case text
        case document
        
        /// Human-readable label
        public var label: String {
            switch self {
            case .image: return "Image"
            case .pdf: return "PDF"
            case .text: return "Text"
            case .document: return "Document"
            }
        }
        
        /// SF Symbol icon name
        public var iconName: String {
            switch self {
            case .image: return "photo.fill"
            case .pdf: return "doc.richtext.fill"
            case .text: return "doc.text.fill"
            case .document: return "doc.fill"
            }
        }
    }
    
    // MARK: - File Extensions
    
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]
    public static let textExtensions: Set<String> = ["txt", "md", "markdown", "log", "csv", "text"]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let officeExtensions: Set<String> = ["docx", "doc"]
    
    // MARK: - Type Detection
    
    /// Determine attachment type from NoteAttachment
    public static func determineType(for attachment: NoteAttachment) -> AttachmentType {
        let type = attachment.type.lowercased()
        let ext = attachment.url.pathExtension.lowercased()
        return determineType(type: type, extension: ext)
    }
    
    /// Determine attachment type from URL
    public static func determineType(for url: URL) -> AttachmentType {
        let ext = url.pathExtension.lowercased()
        return determineType(type: nil, extension: ext)
    }
    
    /// Determine attachment type from type string and extension
    public static func determineType(type: String?, extension ext: String) -> AttachmentType {
        // Check explicit type first
        if let type = type {
            let normalized = type.lowercased()
            if normalized == "image" { return .image }
            if normalized == "pdf" { return .pdf }
            if normalized == "text" { return .text }
        }
        
        // Check extension
        if imageExtensions.contains(ext) {
            return .image
        } else if pdfExtensions.contains(ext) {
            return .pdf
        } else if textExtensions.contains(ext) {
            return .text
        } else {
            return .document
        }
    }
    
    /// Determine attachment type string for creating new attachments
    public static func typeString(for url: URL) -> String {
        determineType(for: url).rawValue
    }
    
    /// Check if file should be processed (supported types)
    public static func isSupported(extension ext: String) -> Bool {
        imageExtensions.contains(ext) || 
        pdfExtensions.contains(ext) || 
        textExtensions.contains(ext) ||
        officeExtensions.contains(ext)
    }
}
