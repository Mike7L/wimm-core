import Foundation

enum LLMText {
    /// Remove markdown code fences if present; otherwise return trimmed input.
    static func stripFences(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        let lines = t.components(separatedBy: "\n")
        let body = lines.dropFirst().joined(separator: "\n")
        if let r = body.range(of: "```", options: .backwards) {
            return String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
