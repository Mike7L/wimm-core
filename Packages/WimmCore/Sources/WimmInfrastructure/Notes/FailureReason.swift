import Foundation
import WimmDomain

// Persist structured failure metadata for a given recording file.
public enum CoreTranscriptionFailureReason: Sendable { case network, decoding, empty, cancelled, tooLarge, rateLimited, badStatus, permissionDenied, notSupported, temporaryUnavailable, privateMode, unknown }

public func persistTranscriptionFailure(file: URL, reason: CoreTranscriptionFailureReason, underlying: Error?) {
    // Same trap as recordRunSuccess: an `_Attach_` file resolves to its parent's
    // sidecar, so a failed attachment would mark the whole note as failed.
    guard !FileStore.isAttachmentFile(file) else { return }
    var meta: [String: Any] = [
        "transcriptionFailure": [
            "reason": String(describing: reason),
            "label": failureReasonLabel(reason, underlying: underlying),
            "timestamp": ISO8601.now
        ]
    ]
    if let ns = underlying as NSError? {
        var details: [String: Any] = [
            "domain": ns.domain,
            "code": ns.code
        ]
        if let msg = ns.userInfo[NSLocalizedDescriptionKey] as? String { details["message"] = msg }
        if let st = ns.userInfo["GStatus"] as? String { details["status"] = st }
        if let body = ns.userInfo["GBody"] as? String { details["body"] = body }
        if let ra = ns.userInfo["GRetryAfter"] as? Int { details["retryAfterSec"] = ra }
        meta["transcriptionFailureDetails"] = details
    }
    FileStore.upsertMetadata(for: file, updates: meta)
}

// Human readable label for UI + transcript failure placeholder
public func failureReasonLabel(_ reason: CoreTranscriptionFailureReason, underlying: Error?) -> String {
    // Try to enrich with details from NSError userInfo when available
    func enrich(_ base: String) -> String {
        guard let ns = underlying as NSError? else { return base }
        if ns.domain == ErrorDomain.badStatus {
            var parts: [String] = [base]
            if ns.code > 0 { parts.append("\(ns.code)") }
            if let s = ns.userInfo["GStatus"] as? String, !s.isEmpty { parts.append(s) }
            if let msg = ns.userInfo[NSLocalizedDescriptionKey] as? String, !msg.isEmpty {
                let trimmed = msg.count > 80 ? String(msg.prefix(77)) + "…" : msg
                parts.append(trimmed)
            }
            if let ra = ns.userInfo["GRetryAfter"] as? Int, ra > 0 { parts.append("retry: \(ra)s") }
            return parts.joined(separator: " · ")
        } else if let msg = ns.userInfo[NSLocalizedDescriptionKey] as? String, !msg.isEmpty {
            // Show custom message from script for special domains
            let trimmed = msg.count > 60 ? String(msg.prefix(57)) + "…" : msg
            return "\(base): \(trimmed)"
        }
        return base
    }
    switch reason {
    case .network: return "network"
    case .decoding: return enrich("decode")
    case .empty: return "empty"
    case .cancelled: return "cancelled"
    case .tooLarge: return "too-large"
    case .rateLimited: return enrich("rate-limit")
    case .badStatus: return enrich("bad-status")
    case .permissionDenied: return enrich("permission")
    case .notSupported: return enrich("unsupported")
    case .temporaryUnavailable: return enrich("temporary")
    case .privateMode: return "private-mode"
    case .unknown: return enrich("err")
    }
}
