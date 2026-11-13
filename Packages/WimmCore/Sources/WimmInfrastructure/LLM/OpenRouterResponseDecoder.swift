import Foundation

// Lightweight decoder for OpenRouter /responses payloads.
// Kept in WimmCore so it can be unit-tested without UI/AppKit deps.
public enum OpenRouterResponseDecoder {
    /// Extracts plain text from common /responses shapes.
    /// Returns nil when no text could be found.
    public static func decodeResponsesText(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 1) Simple top-level key
        if let t = obj["output_text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        // 2) Preferred: array of outputs → content[] with text parts
        if let output = obj["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] {
                    if let t = deepExtractText(from: content) { return t }
                }
            }
        }
        // 3) Alternate: `response` object with `content` array
        if let response = obj["response"] as? [String: Any], let content = response["content"] {
            if let t = deepExtractText(from: content) { return t }
        }
        // 4) Fallbacks: scan common chat-like shapes if present
        if let choices = obj["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any] {
            if let s = msg["content"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            if let content = msg["content"] {
                if let t = deepExtractText(from: content) { return t }
            }
        }
        if let message = obj["message"] as? [String: Any], let content = message["content"] {
            if let t = deepExtractText(from: content) { return t }
        }
        return nil
    }

    // Recursively scan nested arrays/dictionaries for textual parts.
    // Preference order: nodes whose `type` contains "text"; otherwise any `text` fields.
    private static func deepExtractText(from any: Any) -> String? {
        var preferred: [String] = []
        var other: [String] = []
        func walk(_ node: Any, parentType: String? = nil) {
            if let s = node as? String {
                // not a structured part; ignore raw strings unless parentType hints it's text
                if let pt = parentType, pt.contains("text"), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    preferred.append(s)
                }
                return
            }
            if let arr = node as? [Any] {
                for el in arr { walk(el, parentType: parentType) }
                return
            }
            guard let dict = node as? [String: Any] else { return }
            let localType = (dict["type"] as? String)?.lowercased()
            if let t = dict["output_text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preferred.append(t)
            }
            if let s = dict["text"] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let lt = localType, lt.contains("text") { preferred.append(trimmed) } else { other.append(trimmed) }
                }
            } else if let arrS = dict["text"] as? [String] {
                let joined = arrS.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    if let lt = localType, lt.contains("text") { preferred.append(joined) } else { other.append(joined) }
                }
            } else if let arrAny = dict["text"] as? [Any] {
                // Walk nested arrays of parts that may themselves contain { type, text }
                walk(arrAny, parentType: localType ?? parentType)
            }
            // Drill into common nested containers
            if let c = dict["content"] { walk(c, parentType: localType ?? parentType) }
            if let d = dict["data"] { walk(d, parentType: localType ?? parentType) }
            // Walk remaining keys (excluding ones already handled) to catch deeper nesting without duplicating text/type fields
            for (k, v) in dict where !["text", "content", "data", "output_text", "type", "role"].contains(k) {
                walk(v, parentType: localType ?? parentType)
            }
        }
        walk(any)
        let joinedPref = preferred.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joinedPref.isEmpty { return joinedPref }
        let joinedOther = other.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joinedOther.isEmpty ? nil : joinedOther
    }
}
