import Foundation
import WimmDomain

// Presentation and processing edges of `Note`. They live here, not on the
// domain type, so `Note` itself carries no `FileStore` or `NoteProcessor`
// dependency.

extension Note {
    public var timeLabel: String { FileStore.timeStr(absoluteDate) }

}
