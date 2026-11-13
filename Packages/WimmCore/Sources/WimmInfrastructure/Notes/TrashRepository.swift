import Foundation
import WimmDomain

/// Manages trash operations for recordings and their associated files
public actor TrashRepository: TrashRepositoryProtocol {
    private let fileManager = FileManager.default
    
    public init() {}
    
    // MARK: - Trash Operations
    
    /// Move a recording and all its associated files to trash
    /// - Parameter file: The recording file URL to trash
    /// - Returns: The new URL in trash, or nil if operation failed
    @discardableResult
    public func moveToTrash(file: URL) -> URL? {
        RecordingTrashSupport.moveToTrash(
            file: file,
            fileManager: fileManager,
            onFailure: { sourceURL, error in
                log("Failed to move \(sourceURL.lastPathComponent) to trash: \(error)")
            }
        )
    }
    
    /// Restore a file from trash back to recordings directory
    /// - Parameter trashedFile: The file URL in trash to restore
    /// - Returns: The restored URL in recordings, or nil if operation failed
    @discardableResult
    public func restoreFromTrash(file trashedFile: URL) -> URL? {
        RecordingTrashSupport.restoreFromTrash(
            file: trashedFile,
            fileManager: fileManager,
            onFailure: { sourceURL, error in
                log("Failed to restore \(sourceURL.lastPathComponent): \(error)")
            }
        )
    }

    /// Empty the entire trash directory
    public func emptyTrash() {
        let trashDir = FileStore.trashDirectory()
        
        guard let items = try? fileManager.contentsOfDirectory(
            at: trashDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for item in items {
            try? fileManager.removeItem(at: item)

        }
    }

}
