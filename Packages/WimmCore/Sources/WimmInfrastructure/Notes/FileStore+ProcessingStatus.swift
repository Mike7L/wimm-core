import Foundation
import WimmDomain

// The processing-status edge of `FileStore`. It lives here rather than in
// WimmDomain because it reads `MetadataKey` and `LegacyProcessingStatus`,
// both of which are infrastructure concerns — the domain type must not learn
// about the sidecar schema.

extension FileStore {

}
