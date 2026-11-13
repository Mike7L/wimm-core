import Foundation
import CryptoKit

public extension URL {
    var stableUUID: UUID {
        // Create a stable UUID from the file path hash (relative to base dir)
        let relPath = FileStore.relativePath(for: self)
        let data = relPath.data(using: .utf8)!
        let digest = Insecure.MD5.hash(data: data)
        // Use the first 16 bytes of the MD5 hash
        return digest.withUnsafeBytes { buffer in
            return UUID(uuid: buffer.load(as: uuid_t.self))
        }
    }
}
