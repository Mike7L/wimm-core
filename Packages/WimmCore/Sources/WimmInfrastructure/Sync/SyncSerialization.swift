import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// Encoding shared across the sync files. These were file-private helpers
// while all of this lived in one 1200-line file; splitting it up makes them
// module-internal, which is the widest they should ever be.

func wimmSyncDateString(_ date: Date) -> String {
    ISO8601.stringWithFractionalSeconds(from: date)
}

extension JSONEncoder {
    /// One journal record per line; snapshots retain the legacy readable format.
    static var wimmSyncJournalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var wimmSyncEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var wimmSyncDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
