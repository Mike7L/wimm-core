import Foundation
import WimmInfrastructure

/// Adds targets for S citations the editor already used. Never adds prose/citations
/// or rewrites an existing definition; an incorrect existing target stays a finding.
enum SecretaryCitationDefinitions {
    static func repair(document: Data, sources: [[String: Any]]) throws -> (data: Data, ids: [String]) {
        guard let text = String(data: document, encoding: .utf8) else { throw Failure("Document is not UTF-8.") }
        let range = NSRange(text.startIndex..., in: text)
        let defined = try NSRegularExpression(pattern: #"^\[(S[0-9]+)\]:"#, options: .anchorsMatchLines)
        let used = try NSRegularExpression(pattern: #"\[(S[0-9]+)\](?!:)"#)
        func ids(_ regex: NSRegularExpression) -> Set<String> {
            Set(regex.matches(in: text, range: range).map { String(text[Range($0.range(at: 1), in: text)!]) })
        }
        let missing = ids(used).subtracting(ids(defined))
        let known = Dictionary(uniqueKeysWithValues: sources.map { ($0["source_id"] as! String, $0) })
        var additions: [String] = [], added: [String] = []
        for id in missing.sorted() {
            guard let source = known[id] else { continue } // An unknown S number must fail verification.
            guard let raw = source["path"] as? String, let path = raw.removingPercentEncoding,
                  path.hasPrefix("../recordings/"), !path.dropFirst(3).components(separatedBy: "/").contains(".."),
                  path.rangeOfCharacter(from: .newlines) == nil, !path.contains("\\"),
                  let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) else {
                throw Failure("\(id): unsafe citation target in registry.")
            }
            additions.append("[\(id)]: \(encoded)"); added.append(id)
        }
        guard !additions.isEmpty else { return (document, []) }
        let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return (document + Data((separator + additions.joined(separator: "\n") + "\n").utf8), added)
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
