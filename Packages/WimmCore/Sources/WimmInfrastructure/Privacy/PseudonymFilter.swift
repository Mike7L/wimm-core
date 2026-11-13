import CryptoKit
import Foundation
import WimmDomain

/// Placeholder types. The raw value is the letter inside the token (`⟦P3⟧`).
public enum PseudonymKind: String, Codable, CaseIterable, Sendable {
    case person = "P"
    case org = "O"
    case place = "L"
    case other = "X"
    case email = "E"
    case phone = "T"
    case iban = "I"
    case address = "A"
    case card = "C"

    public init(_ kind: PersonalGlossaryKind?) {
        switch kind {
        case .person: self = .person
        case .org: self = .org
        case .place: self = .place
        case .other, nil: self = .other
        }
    }
}

/// Which rule found a span; shown in the local preview legend.
public enum PseudonymDetector: String, Codable, CaseIterable, Sendable {
    case email, iban, card, phone, street, postcode, dictionary
}

/// Every error names categories or tokens, never a detected value.
public enum PseudonymizationError: Error, LocalizedError, Equatable, Sendable {
    /// The input already contains `⟦` or `⟧`, so tokens in the answer could not be told apart.
    case inputContainsTokenDelimiters
    /// The outbound re-scan still found identifiers after masking.
    case outboundLeak(kinds: [String])
    /// The answer references a token that is not in this request's map.
    case unknownToken(String)
    /// The answer contains a bracket or token shape the grammar does not allow.
    case malformedToken(String)
    /// Private mode refused a cloud request that was not pseudonymized (or cannot be: audio, images).
    case cloudRequestRefused(String)

    public var errorDescription: String? {
        switch self {
        case .inputContainsTokenDelimiters: return "Private mode: the note already contains ⟦ ⟧ token brackets."
        case .outboundLeak(let kinds): return "Private mode: identifiers survived masking (\(kinds.joined(separator: ","))); request blocked."
        case .unknownToken(let token): return "Private mode: the model returned an unknown placeholder \(token)."
        case .malformedToken(let token): return "Private mode: the model returned a malformed placeholder \(token)."
        case .cloudRequestRefused(let what): return "Private mode is on: \(what) is not sent to cloud providers. Turn private mode off in Settings or use local transcription."
        }
    }
}

/// The per-request join between placeholders and real values. Lives only on
/// this device: never in the payload, never in CloudKit.
public struct PseudonymMap: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let kind: PseudonymKind
        public let detector: PseudonymDetector
        /// What a bare token unmasks to.
        public let canonical: String
        /// Other surface forms seen in this request; `⟦P3:f1⟧` is `forms[0]`.
        public var forms: [String]
        /// Stored grammatical forms (`dat` → "Маше"); a case without one falls back to `canonical`.
        public var caseForms: [String: String]
    }

    /// Keyed by token id without brackets, e.g. `"P3"`.
    public internal(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Occurrences are not counted, entities are: `{"P": 2, "E": 1}`.
    public var counts: [String: Int] {
        entries.values.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Canonical bytes: sorted keys, so the same map always hashes the same.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func sha256() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds one request's map. Token numbers are drawn at random per request,
/// so `P3` in one request says nothing about `P3` in another.
public final class PseudonymSession {
    public private(set) var map = PseudonymMap()
    private var tokenByEntity: [String: String] = [:]
    private var used: [PseudonymKind: Set<Int>] = [:]
    private let next: () -> UInt64

    public convenience init() {
        var system = SystemRandomNumberGenerator()
        self.init { system.next() }
    }

    /// `random` supplies raw 64-bit values; tests pass a seeded generator.
    public init(random: @escaping () -> UInt64) {
        self.next = random
    }

    fileprivate func token(entity: String, kind: PseudonymKind, detector: PseudonymDetector, canonical: String,
                           caseForms: [String: String], surface: String) -> String {
        let id: String
        if let existing = tokenByEntity[entity] {
            id = existing
        } else {
            var taken = used[kind, default: []]
            let ceiling = max(99, taken.count * 4 + 8)
            var number = Int(next() % UInt64(ceiling)) + 1
            while taken.contains(number) { number = Int(next() % UInt64(ceiling)) + 1 }
            taken.insert(number)
            used[kind] = taken
            id = "\(kind.rawValue)\(number)"
            tokenByEntity[entity] = id
            map.entries[id] = .init(kind: kind, detector: detector, canonical: canonical, forms: [], caseForms: caseForms)
        }
        guard var entry = map.entries[id], surface != entry.canonical else { return "⟦\(id)⟧" }
        let index: Int
        if let found = entry.forms.firstIndex(of: surface) {
            index = found
        } else {
            entry.forms.append(surface)
            map.entries[id] = entry
            index = entry.forms.count - 1
        }
        return "⟦\(id):f\(index + 1)⟧"
    }
}

/// Deterministic detectors plus the explicit personal dictionary. Stage 1 of
/// `docs/Pseudonymization_Design.md`: no model, no registry, no learning.
public struct PseudonymFilter: Sendable {
    /// One sensitive vocabulary entry, matched whole-token and literally
    /// (case-insensitive), over the canonical name and its recognition variants.
    public struct DictionaryTerm: Equatable, Sendable {
        public let canonical: String
        public let forms: [String]
        public let kind: PseudonymKind
        public let caseForms: [String: String]

        public init(canonical: String, forms: [String] = [], kind: PseudonymKind = .other,
                    caseForms: [String: String] = [:]) {
            self.canonical = canonical
            self.forms = forms
            self.kind = kind
            self.caseForms = caseForms
        }

        public init(term: PersonalGlossaryTerm) {
            self.init(canonical: term.canonical, forms: term.observedForms, kind: PseudonymKind(term.kind))
        }
    }

    public struct Detection: Equatable, Sendable {
        public let range: NSRange
        public let kind: PseudonymKind
        public let detector: PseudonymDetector
        /// Index into the filter's dictionary, nil for structured identifiers.
        public let dictionaryIndex: Int?
    }

    private struct Matcher: Sendable {
        let regex: NSRegularExpression
        let dictionaryIndex: Int
    }

    public let dictionary: [DictionaryTerm]
    private let dictionaryMatchers: [Matcher]

    public init(dictionary: [DictionaryTerm] = []) {
        self.dictionary = dictionary
        var matchers: [Matcher] = []
        for (index, term) in dictionary.enumerated() {
            // Single letters ("Я") would mask ordinary words; the store allows them, masking does not.
            let forms = Set(([term.canonical] + term.forms + Array(term.caseForms.values)).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { $0.count >= 2 })
            for form in forms.sorted() {
                let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: form) + #"(?![\p{L}\p{N}_])"#
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    matchers.append(Matcher(regex: regex, dictionaryIndex: index))
                }
            }
        }
        self.dictionaryMatchers = matchers
    }

    // MARK: Detection

    /// Non-overlapping detections in text order. Overlaps resolve longest-first.
    public func detect(in text: String) -> [Detection] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var candidates: [Detection] = []

        for match in Self.email.matches(in: text, range: whole) {
            candidates.append(.init(range: match.range, kind: .email, detector: .email, dictionaryIndex: nil))
        }
        let ibanSpans = Self.scan(Self.ibanCandidate, in: ns, isValid: Self.isValidIBAN)
        for range in ibanSpans {
            candidates.append(.init(range: range, kind: .iban, detector: .iban, dictionaryIndex: nil))
        }
        let outsideIBAN: (NSRange) -> Bool = { range in
            !ibanSpans.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for range in Self.scan(Self.cardCandidate, in: ns, isValid: Self.isValidCard, accept: outsideIBAN) {
            candidates.append(.init(range: range, kind: .card, detector: .card, dictionaryIndex: nil))
        }
        for range in Self.scan(Self.phoneCandidate, in: ns, isValid: Self.isPlausiblePhone, accept: outsideIBAN) {
            candidates.append(.init(range: range, kind: .phone, detector: .phone, dictionaryIndex: nil))
        }
        for (regex, detector) in [(Self.streetCompound, PseudonymDetector.street), (Self.streetSeparate, .street), (Self.postcodeCity, .postcode)] {
            for match in regex.matches(in: text, range: whole) {
                candidates.append(.init(range: match.range, kind: .address, detector: detector, dictionaryIndex: nil))
            }
        }
        for matcher in dictionaryMatchers {
            for match in matcher.regex.matches(in: text, range: whole) {
                candidates.append(.init(range: match.range, kind: dictionary[matcher.dictionaryIndex].kind,
                                        detector: .dictionary, dictionaryIndex: matcher.dictionaryIndex))
            }
        }

        let ordered = candidates.sorted {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
        var accepted: [Detection] = []
        for candidate in ordered where !accepted.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
            accepted.append(candidate)
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    // MARK: Mask / unmask

    /// Masks `text` into `session`'s map. Several fields of one request share a session.
    ///
    /// Longest-first can drop a shorter identifier that only overlapped the
    /// winner ("Musterstraße 12 x" vs "x_y@example.org"); once the winner is a
    /// token the loser stands alone again, so masking repeats until nothing is
    /// found. Detections never span a token, which keeps unmask single-pass.
    public func mask(_ text: String, session: PseudonymSession) throws -> String {
        guard !text.contains("⟦"), !text.contains("⟧") else {
            throw PseudonymizationError.inputContainsTokenDelimiters
        }
        var current = text
        for _ in 0..<4 {
            let (next, replaced) = maskPass(current, session: session)
            current = next
            if replaced == 0 { break }
        }
        return current
    }

    private func maskPass(_ text: String, session: PseudonymSession) -> (String, Int) {
        let ns = text as NSString
        let detections = detect(in: text).filter {
            let surface = ns.substring(with: $0.range)
            return !surface.contains("⟦") && !surface.contains("⟧")
        }
        var output = ""
        var cursor = 0
        for detection in detections {
            output += ns.substring(with: NSRange(location: cursor, length: detection.range.location - cursor))
            let surface = ns.substring(with: detection.range)
            if let index = detection.dictionaryIndex {
                let term = dictionary[index]
                output += session.token(entity: "dict:\(index)", kind: term.kind, detector: .dictionary, canonical: term.canonical,
                                        caseForms: term.caseForms, surface: surface)
            } else {
                output += session.token(entity: "\(detection.kind.rawValue):\(surface)", kind: detection.kind, detector: detection.detector,
                                        canonical: surface, caseForms: [:], surface: surface)
            }
            cursor = NSMaxRange(detection.range)
        }
        output += ns.substring(from: cursor)
        return (output, detections.count)
    }

    /// Convenience for one field with a fresh random map.
    public func mask(_ text: String) throws -> (masked: String, map: PseudonymMap) {
        let session = PseudonymSession()
        let masked = try mask(text, session: session)
        return (masked, session.map)
    }

    /// Outbound guard: any detector hit on already-masked text blocks the request.
    public func assertClean(_ masked: String) throws {
        let hits = detect(in: masked)
        guard hits.isEmpty else {
            throw PseudonymizationError.outboundLeak(kinds: Array(Set(hits.map(\.kind.rawValue))).sorted())
        }
    }

    /// Inbound: every token must be well formed and known to `map`. A bare
    /// token gives the canonical form, `:fN` a surface form seen in the request,
    /// `:case` the stored case form or, without one, the canonical form.
    public static func unmask(_ text: String, map: PseudonymMap) throws -> String {
        guard text.contains("⟦") || text.contains("⟧") else { return text }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in bracketGroup.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if between.contains("⟦") || between.contains("⟧") {
                throw PseudonymizationError.malformedToken(String(between.filter { $0 == "⟦" || $0 == "⟧" }))
            }
            output += between
            let group = ns.substring(with: match.range)
            guard let parts = strictToken.firstMatch(in: group, range: NSRange(location: 0, length: (group as NSString).length)) else {
                throw PseudonymizationError.malformedToken(String(group.prefix(24)))
            }
            let g = group as NSString
            let id = g.substring(with: parts.range(at: 1))
            guard let entry = map.entries[id] else { throw PseudonymizationError.unknownToken("⟦\(id)⟧") }
            let suffixRange = parts.range(at: 3)
            if suffixRange.location == NSNotFound {
                output += entry.canonical
            } else {
                let suffix = g.substring(with: suffixRange)
                if suffix.hasPrefix("f"), let n = Int(suffix.dropFirst()) {
                    guard n >= 1, n <= entry.forms.count else { throw PseudonymizationError.malformedToken(group) }
                    output += entry.forms[n - 1]
                } else {
                    output += entry.caseForms[suffix] ?? entry.canonical
                }
            }
            cursor = NSMaxRange(match.range)
        }
        let tail = ns.substring(from: cursor)
        if tail.contains("⟦") || tail.contains("⟧") {
            throw PseudonymizationError.malformedToken(String(tail.filter { $0 == "⟦" || $0 == "⟧" }))
        }
        return output + tail
    }

    // MARK: Validators

    static func isValidIBAN(_ candidate: String) -> Bool {
        let compact = candidate.filter { $0 != " " }
        guard (15...34).contains(compact.count), compact.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for char in rearranged {
            if let digit = char.wholeNumberValue {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = char.asciiValue {
                remainder = (remainder * 100 + Int(ascii) - 55) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    static func isValidCard(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    static func isPlausiblePhone(_ candidate: String) -> Bool {
        let digits = candidate.filter(\.isNumber).count
        guard (10...15).contains(digits) else { return false }
        let whole = NSRange(location: 0, length: (candidate as NSString).length)
        return dateShape.firstMatch(in: candidate, range: whole) == nil
    }

    /// Like `matches(in:)`, but a candidate that validates only as a shorter
    /// prefix releases the rest of its text, so an identifier glued behind
    /// another one ("IBAN 0151 23456789") is still found.
    static func scan(_ regex: NSRegularExpression, in text: NSString,
                     isValid: (String) -> Bool, accept: (NSRange) -> Bool = { _ in true }) -> [NSRange] {
        var found: [NSRange] = []
        var location = 0
        while location < text.length,
              let match = regex.firstMatch(in: text as String, range: NSRange(location: location, length: text.length - location)) {
            if let range = longestValidPrefix(of: match.range, in: text, isValid: isValid), accept(range) {
                found.append(range)
                location = NSMaxRange(range)
            } else {
                location = match.range.location + 1
            }
        }
        return found
    }

    /// Greedy candidate regexes overrun into neighbouring numbers and words.
    /// Walk back to the longest prefix that ends on a token boundary and validates.
    static func longestValidPrefix(of range: NSRange, in text: NSString, isValid: (String) -> Bool) -> NSRange? {
        var length = range.length
        while length > 0 {
            let end = range.location + length
            let last = text.substring(with: NSRange(location: end - 1, length: 1))
            let next = end < text.length ? text.substring(with: NSRange(location: end, length: 1)) : " "
            if last.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains),
               !next.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) {
                let candidate = NSRange(location: range.location, length: length)
                if isValid(text.substring(with: candidate)) { return candidate }
            }
            length -= 1
        }
        return nil
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals; a typo is a programmer error caught by the golden tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let boundaryBefore = #"(?<![\p{L}\p{N}])"#
    private static let boundaryAfter = #"(?![\p{L}\p{N}])"#

    static let email = regex(
        #"(?<![\p{L}\p{N}._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"# + boundaryAfter)
    static let ibanCandidate = regex(
        boundaryBefore + #"[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,32}"#)
    static let cardCandidate = regex(
        boundaryBefore + #"\d(?:[ -]?\d){12,22}"#)
    static let phoneCandidate = regex(
        #"(?<![\p{L}\p{N}+\-/.])(?:\+|\(\+?)?\d[\d ()\-/.]{8,24}\d"#)
    static let dateShape = regex(
        #"\d{4}-\d{2}-\d{2}|\d{1,2}\.\d{1,2}\.\d{2,4}"#)
    private static let streetSuffixes = "straße|strasse|str\\.|weg|allee|platz|gasse|ring|damm|ufer|chaussee|steig|pfad"
    private static let houseNumber = #"[ \t]*\d{1,4}(?:[ \t]?[a-zA-Z](?![\p{L}\p{N}_@%+-]))?"# + boundaryAfter
    /// "Hauptstraße 5", "Lindenstr. 12a"
    static let streetCompound = regex(
        boundaryBefore + #"[A-ZÄÖÜ][\p{Ll}ß-]*(?:"# + streetSuffixes + ")" + houseNumber)
    /// "Berliner Straße 12", "Karl-Marx-Allee 5"
    static let streetSeparate = regex(
        boundaryBefore + #"(?:[A-ZÄÖÜ][\p{Ll}ß]+[ -]){1,3}(?:Straße|Strasse|Str\.|Weg|Allee|Platz|Gasse|Ring|Damm|Ufer|Chaussee)"# + houseNumber)
    /// "10115 Berlin", "D-60311 Frankfurt am Main"; amounts ("10000 Euro") are excluded.
    static let postcodeCity = regex(
        boundaryBefore + #"(?:D-)?\d{5}[ \t]+(?!(?:Euro|EUR|Stück|Mal|Jahre|Tage|Menschen|Meter|Kilometer|Mitarbeiter|Einwohner|Punkte|Dollar|Rubel)(?![\p{L}]))[A-ZÄÖÜ][\p{Ll}ß]+(?:-[A-ZÄÖÜ][\p{Ll}ß]+)*(?:[ \t](?:am|an der|im|bei|ob der)[ \t][A-ZÄÖÜ][\p{Ll}ß]+)?"# + boundaryAfter)
    /// Anything bracketed, so a broken token cannot slip through as text.
    static let bracketGroup = regex(#"⟦[^⟦⟧]{0,40}⟧"#)
    static let strictToken = regex(
        #"^⟦([A-Z]\d{1,4})(\|[mfn])?(?::([a-z]{2,8}|f\d{1,3}))?⟧$"#)
}

/// Archives maps by hash so an analysis can be replayed. Local only: the
/// folder sits beside `Glossary/`, outside `Recordings/`, which CloudSync reads.
public struct PseudonymMapArchive: Sendable {
    public static let shared = PseudonymMapArchive()
    public let directory: URL

    public init(directory: URL = StoragePaths.baseDirectory().appendingPathComponent("Pseudonymization")) {
        self.directory = directory
    }

    @discardableResult
    public func archive(_ map: PseudonymMap) throws -> String {
        let data = try map.canonicalData()
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent("maps")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(sha).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        return sha
    }

    public func map(sha256: String) throws -> PseudonymMap {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw CocoaError(.fileReadInvalidFileName) }
        return try JSONDecoder().decode(PseudonymMap.self, from: Data(contentsOf: directory.appendingPathComponent("maps/\(sha256).json")))
    }
}

/// Stamped as `analysisPseudonymization` after a successful masked analysis.
public struct PseudonymizationReceipt: Equatable, Sendable {
    public static let schema = "PseudonymizationReceipt@v1"
    public static let version = "stage1-2026-10-19"
    public let mapSha256: String
    public let counts: [String: Int]

    public var metadata: [String: Any] {
        ["schema": Self.schema, "version": Self.version, "mapSha256": mapSha256, "counts": counts]
    }
}
