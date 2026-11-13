import Foundation

/// Shared retry heuristic used by both QueueSupervisor and ProcessFileUseCase.
///
/// Returns true for transient network or server errors that are worth retrying:
///   - URLError (timeout, no connection, etc.)
///   - HTTP 408 / 425 / 429
///   - HTTP 5xx
public enum RetryPolicy {
    public static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }

        switch nsError.code {
        case 408, 425, 429: return true
        case 500...599:     return true
        default:            return false
        }
    }
}
