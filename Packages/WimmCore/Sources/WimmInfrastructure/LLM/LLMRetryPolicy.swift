import Foundation

public enum LLMRetryPolicy {
    public static func shouldRetry(statusCode: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(statusCode)
    }

    public static func shouldRetry(error: Error) -> Bool {
        if error is URLError {
            return true
        }
        let ns = error as NSError
        if shouldRetry(statusCode: ns.code) {
            return true
        }
        return false
    }

    public static func retryAfterSeconds(from header: String?) -> Int? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let secs = Int(trimmed), secs > 0 else { return nil }
        return secs
    }

    public static func delaySeconds(attempt: Int, error: Error, capSeconds: Double = 12.0) -> Double {
        let ns = error as NSError
        if let retryAfter = ns.userInfo["RetryAfterSec"] as? Int, retryAfter > 0 {
            return min(Double(retryAfter), capSeconds)
        }
        let base = max(1, attempt)
        return min(Double(base) * 1.5, capSeconds)
    }
}

