import Foundation

/// The document as the dossier model should read it: the text a person would say, without the
/// machinery around it. Port of the web panel's `plainDossierText` (`server/shouldersApi.ts`);
/// keep the two in step.
///
/// Measured on the real document (2026-11-20): 641 KB → 451 KB. Citation definition lines
/// (`[S123]: ../recordings/….meta.json`) alone were 167 KB and 5,376 source marks were
/// scattered through the text; none of it belongs in a spoken dossier.
enum ShouldersDossierText {
    /// A run without a space this long is data (base64, an address), not a word.
    static let unspeakableRun = 200

    static func plain(_ markdown: String) -> String {
        var text = withoutReferenceDefinitions(markdown)
        for (pattern, template, options) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let rules: [(String, String, NSRegularExpression.Options)] = [
        (#"^<a\s+id="[^"]+"\s*></a>[ \t]*$"#, "", [.anchorsMatchLines]),
        (#"\s*→\s*\[[^\]]+\]\(#[^)]+\)"#, "", []),
        (#"!\[[^\]]*\]\([^)]*\)"#, "", []),
        (#"<img\b[^>]*>"#, "", [.caseInsensitive]),
        (#"\[[A-Z]+\d+\]\([^)]*\)"#, "", []),
        (#"(?<!!)\[[A-Z]+\d+\](?![(:])"#, "", []),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1", []),
        (#"<?\bhttps?://[^\s>)]+>?"#, "", [.caseInsensitive]),
        (#"\S{\#(unspeakableRun),}"#, "", []),
        (#"(\S) {2,}(?=\S)"#, "$1 ", []),
        (#"[ \t]+([.,;:])"#, "$1", []),
        (#"[ \t]+$"#, "", [.anchorsMatchLines]),
        (#"^---+[ \t]*$"#, "", [.anchorsMatchLines]),
        (#"\n{3,}"#, "\n\n", []),
    ]

    /// Drops `[id]: target` lines outside code fences; HTML comments and fenced text stay.
    private static func withoutReferenceDefinitions(_ markdown: String) -> String {
        var out: [Substring] = [], fence: String?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                out.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3)); out.append(line); continue
            }
            if trimmed.range(of: #"^\[[^\]]+\]:\s*\S+"#, options: .regularExpression) != nil { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
