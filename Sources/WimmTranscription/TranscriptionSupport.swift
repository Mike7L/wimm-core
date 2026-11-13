import Foundation
import WimmInfrastructure
import WimmDomain

public enum TranscriptionSupport {
    public static func guessMime(for ext: String) -> String {
        switch ext.lowercased() {
        case "m4a": return "audio/m4a"
        case "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav", "caf": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "opus", "ogg", "oga": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    public static func buildMultipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        fileParam: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) throws -> Data {
        var data = Data()
        let crlf = "\r\n"
        func append(_ string: String) {
            if let chunk = string.data(using: .utf8) {
                data.append(chunk)
            }
        }
        for (name, value) in fields {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            append("\(value)\(crlf)")
        }
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"\(fileParam)\"; filename=\"\(filename)\"\(crlf)")
        append("Content-Type: \(mimeType)\(crlf)\(crlf)")
        data.append(fileData)
        append(crlf)
        append("--\(boundary)--\(crlf)")
        return data
    }

    public static func decodeWhisperResponseText(from data: Data) throws -> String {
        if let plain = String(data: data, encoding: .utf8) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.first != "{" { return trimmed }
        }
        struct WhisperText: Decodable { let text: String? }
        if let textPayload = try? JSONDecoder().decode(WhisperText.self, from: data) {
            if let text = textPayload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        struct WhisperVerbose: Decodable {
            struct Segment: Decodable { let text: String }
            let segments: [Segment]?
            let text: String?
        }
        if let verbose = try? JSONDecoder().decode(WhisperVerbose.self, from: data) {
            if let text = verbose.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            let combined = verbose.segments?.map { $0.text }.joined(separator: " ") ?? ""
            let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw NSError(domain: ErrorDomain.noText, code: 0)
    }

    /// Sentinel the transcription model emits when the audio has no speech. Detecting
    /// an explicit token is far more reliable than asking the model to "return nothing"
    /// — models resist empty output and fabricate plausible text on silence instead.
    public static let noSpeechSentinel = "[[NO_SPEECH]]"

    /// True when `text` is only the no-speech sentinel (tolerating brackets/case/spacing).
    public static func isNoSpeechSentinel(_ text: String) -> Bool {
        let core = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter }
        return core == "NOSPEECH"
    }

    public static func splitAgentRecommendation(from text: String) -> (text: String, agent: String?, reason: String?) {
        if isNoSpeechSentinel(text) { return ("", nil, nil) }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed, nil, nil)
        }

        var agent: String?
        var reason: String?
        var kept: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("agent_recommendation:") {
                let start = trimmed.index(trimmed.startIndex, offsetBy: "agent_recommendation:".count)
                let raw = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    if let sep = raw.range(of: " - ") ?? raw.range(of: " | ") {
                        let agentRaw = raw[..<sep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                        let reasonRaw = raw[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                        agent = agentRaw.isEmpty ? nil : String(agentRaw)
                        reason = reasonRaw.isEmpty ? nil : String(reasonRaw)
                    } else {
                        agent = String(raw)
                    }
                }
                continue
            }
            kept.append(line)
        }

        let clean = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if isNoSpeechSentinel(clean) { return ("", agent, reason) }
        return (clean, agent, reason)
    }

    public static func classify(_ error: Error) -> TranscriptionFailureReason {
        if error is CancellationError { return .cancelled }
        if PrivateMode.isRefusal(error) { return .privateMode }
        if (error as? URLError) != nil { return .network }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain { return .decoding }
        if ns.domain == ErrorDomain.noText { return .empty }
        if ns.domain == ErrorDomain.badStatus {
            if ns.code == 429 { return .rateLimited }
            if ns.code == 401 || ns.code == 403 { return .permissionDenied }
            if ns.code == 413 { return .tooLarge }
            if ns.code == 415 { return .notSupported }
            if ns.code == 400 {
                let message = ((ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? "").lowercased()
                if message.contains("invalid input")
                    || message.contains("input_audio")
                    || message.contains("input audio")
                    || message.contains("no endpoints found that support input audio")
                    || message.contains("does not support")
                    || message.contains("unsupported") {
                    return .notSupported
                }
            }
            if ns.code == 404 {
                let message = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
                if message.lowercased().contains("no endpoints found that support input audio") {
                    return .notSupported
                }
            }
            if ns.code == 503 || (ns.userInfo["GStatus"] as? String) == "UNAVAILABLE" { return .temporaryUnavailable }
            if (ns.userInfo["GStatus"] as? String) == "RESOURCE_EXHAUSTED" { return .rateLimited }
            if (ns.userInfo["GStatus"] as? String) == "INVALID_ARGUMENT" {
                let message = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
                if message.lowercased().contains("too large") || message.lowercased().contains("exceeds") { return .tooLarge }
            }
            return .badStatus
        }
        if String(describing: error).contains("empty") { return .empty }
        return .unknown
    }

    public static func shouldRotate(after error: Error, reason: TranscriptionFailureReason) -> Bool {
        switch reason {
        case .permissionDenied, .rateLimited, .temporaryUnavailable, .badStatus:
            return true
        default:
            if let ns = error as NSError?, ns.domain == ErrorDomain.badStatus, (500...599).contains(ns.code) {
                return true
            }
            return false
        }
    }
}
