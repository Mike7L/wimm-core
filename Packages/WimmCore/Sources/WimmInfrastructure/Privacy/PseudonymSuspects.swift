import Foundation

/// A word in an already-masked text that still looks identifying.
public struct PseudonymSuspect: Sendable, Equatable, Identifiable {
    public enum Reason: String, Sendable {
        /// A capitalized Cyrillic word mid-sentence, or several capitalized words in a row.
        case name
        /// A short capitalized «Название» in guillemets.
        case quotedName
        /// A 2–5 letter acronym outside the common list (TK, BHI).
        case acronym
        /// Capitalized words ending in GmbH, AG, e.V. …
        case organization
        /// Eight or more digits in a row the regex detectors left alone.
        case longNumber
    }

    public let surface: String
    public let reason: Reason
    /// Occurrences in the text.
    public let count: Int
    public var id: String { surface }
}

/// Review list for the private-text preview: what the deterministic masking left
/// visible but a reader would likely call identifying. It never masks anything —
/// the user turns a suspect into a vocabulary term (Remember name), and the next
/// preview masks it through the normal egress path.
///
/// Measured on the 2026-10-24 depersonalization holdout (12 real paragraphs,
/// dictionary-only masking leaked 10 of 15 identifiers): these rules surfaced
/// all of them except two acronyms, which is why acronyms are a reason too.
public enum PseudonymSuspects {
    public static let maximum = 40

    /// `text` is masked text (tokens ⟦…⟧ are skipped). `ignoring` holds lowercased
    /// surfaces the user dismissed.
    public static func find(inMasked text: String, ignoring: Set<String> = []) -> [PseudonymSuspect] {
        // Section headers the context builder writes ("[MAIN_TEXT lang=ru]") are not note text.
        let unheaded = sectionHeader.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        // A token is a name: keep it a word so the next capital is mid-sentence.
        let plain = tokenPattern.stringByReplacingMatches(
            in: unheaded, range: NSRange(location: 0, length: (unheaded as NSString).length), withTemplate: "x")
        // One pass: graphemes, their UTF-16 offsets (positions are UTF-16 throughout) and word flags.
        var chars: [Character] = []
        var offsets: [Int] = []
        var wordFlags: [Bool] = []
        var offset = 0
        for c in plain {
            chars.append(c)
            offsets.append(offset)
            wordFlags.append(c.isLetter || c.isNumber)
            offset += c.utf16.count
        }
        func isWord(_ i: Int) -> Bool { i >= 0 && i < chars.count && wordFlags[i] }

        var tokens: [(lo: Int, hi: Int)] = []
        var i = 0
        while i < chars.count {
            guard wordFlags[i] else { i += 1; continue }
            var j = i + 1
            while j < chars.count, wordFlags[j] || ("-'’".contains(chars[j]) && isWord(j + 1)) { j += 1 }
            tokens.append((i, j))
            i = j
        }
        func word(_ t: (lo: Int, hi: Int)) -> String { String(chars[t.lo..<t.hi]) }
        func atSentenceStart(_ lo: Int) -> Bool {
            var p = lo - 1
            while p >= 0, chars[p] == " " || chars[p] == "\t" { p -= 1 }
            return p < 0 || sentenceOpeners.contains(chars[p])
        }
        func isAcronym(_ w: String) -> Bool { (2...5).contains(w.count) && w.allSatisfy { $0.isUppercase && $0.isLetter } }
        func isCapitalized(_ w: String) -> Bool {
            guard let f = w.first, f.isUppercase, f.isLetter, w.count >= 2, !isAcronym(w) else { return false }
            return !stopwords.contains(w.lowercased())
        }
        // Most tokens start lowercase; reject them before building a String.
        func startsUpper(_ t: (lo: Int, hi: Int)) -> Bool { chars[t.lo].isUppercase }
        func isCyrillic(_ w: String) -> Bool { w.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }

        var found: [(surface: String, reason: PseudonymSuspect.Reason, at: Int)] = []
        var k = 0
        while k < tokens.count {
            guard startsUpper(tokens[k]) else { k += 1; continue }
            let w = word(tokens[k])
            if isAcronym(w) {
                if !commonAcronyms.contains(w.lowercased()) { found.append((w, .acronym, offsets[tokens[k].lo])) }
                k += 1
                continue
            }
            guard isCapitalized(w) else { k += 1; continue }
            var end = k
            while end + 1 < tokens.count, startsUpper(tokens[end + 1]), isCapitalized(word(tokens[end + 1])),
                  tokens[end + 1].lo == tokens[end].hi + 1, chars[tokens[end].hi] == " " { end += 1 }
            let surface = String(chars[tokens[k].lo..<tokens[end].hi])
            if end > k {
                found.append((surface, .name, offsets[tokens[k].lo]))
            } else if isCyrillic(w), !atSentenceStart(tokens[k].lo) {
                // A single capitalized Latin word is skipped: German capitalizes every noun.
                found.append((surface, .name, offsets[tokens[k].lo]))
            }
            k = end + 1
        }

        let ns = plain as NSString
        let all = NSRange(location: 0, length: ns.length)
        for m in organization.matches(in: plain, range: all) {
            found.append((ns.substring(with: m.range), .organization, m.range.location))
        }
        for m in quoted.matches(in: plain, range: all) {
            let inner = ns.substring(with: m.range(at: 1))
            let first = inner.split(separator: " ").first.map { String($0).lowercased() } ?? ""
            guard inner.first?.isUppercase == true, inner.split(separator: " ").count <= 3,
                  !inner.contains("?"), !inner.contains("!"), !stopwords.contains(first) else { continue }
            found.append((inner, .quotedName, m.range(at: 1).location))
        }
        for m in longNumber.matches(in: plain, range: all) {
            found.append((ns.substring(with: m.range), .longNumber, m.range.location))
        }

        // One row per surface, at its first position. On a tie of surfaces the specific
        // reason wins ("Holzmann Bau GmbH" is an organization, not just a name).
        var unique: [String: (reason: PseudonymSuspect.Reason, at: Int)] = [:]
        for f in found where !ignoring.contains(f.surface.lowercased()) {
            if let seen = unique[f.surface] {
                let reason = seen.reason == .name ? f.reason : seen.reason
                unique[f.surface] = (reason, min(seen.at, f.at))
            } else {
                unique[f.surface] = (f.reason, f.at)
            }
        }
        // A longer suspect hides the words it contains. Only multi-word suspects can
        // contain another one, so compare against those (a 1 MB note has thousands of
        // single names; comparing every pair was quadratic).
        let multiWord = unique.keys.filter { $0.contains(" ") }
        let partsOfMultiWord = Set(multiWord.flatMap { $0.split(separator: " ").map(String.init) })
        let kept = unique.filter { surface, _ in
            surface.contains(" ")
                ? !multiWord.contains { $0 != surface && $0.contains(surface) }
                : !partsOfMultiWord.contains(surface) && !multiWord.contains { $0.contains(surface) }
        }
        return kept.sorted { $0.value.at < $1.value.at }.prefix(maximum).map { entry in
            PseudonymSuspect(surface: entry.key, reason: entry.value.reason, count: occurrences(of: entry.key, in: ns))
        }
    }

    /// Guessed Russian case forms of one capitalized Cyrillic word, to prefill a
    /// vocabulary term's variants. Masking matches forms literally, so "Оксана"
    /// alone would leave "Оксаной" visible. The user sees and edits the list.
    public static func caseFormGuesses(_ word: String) -> [String] {
        guard word.count >= 3, !word.contains(" "), word.first?.isUppercase == true,
              word.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } }) else { return [] }
        let chars = Array(word)
        let lower = word.lowercased()
        func stem(_ drop: Int) -> String { String(chars.dropLast(drop)) }
        var base = word
        var endings: [String]
        if lower.hasSuffix("ия") {
            base = stem(2); endings = ["ия", "ии", "ию", "ией"]
        } else if lower.hasSuffix("я") {
            base = stem(1); endings = ["я", "и", "е", "ю", "ей"]
        } else if lower.hasSuffix("а") {
            base = stem(1)
            let last = base.lowercased().last ?? " "
            endings = ["а", "гкхжшщч".contains(last) ? "и" : "ы", "е", "у", "жшщч".contains(last) ? "ей" : "ой"]
        } else if lower.hasSuffix("й") {
            base = stem(1); endings = ["й", "я", "ю", "ем", "е"]
        } else if lower.hasSuffix("ь") {
            base = stem(1); endings = ["ь", "я", "ю", "ем", "е", "и", "ью"]
        } else if let last = lower.last, "бвгджзклмнпрстфхцчшщ".contains(last) {
            endings = ["", "а", "у", "ом", "е"]
        } else {
            return []  // -о, -е, -и, -у: indeclinable
        }
        return endings.map { base + $0 }.filter { $0 != word }
    }

    // MARK: - Tables

    private static let tokenPattern = try! NSRegularExpression(pattern: "⟦[^⟦⟧]{1,40}⟧")
    private static let sectionHeader = try! NSRegularExpression(pattern: #"\[(?:MAIN_TEXT|ATTACHMENT_\d+_OCR)(?:[ \t][^\]\n]*)?\]"#)
    private static let organization = try! NSRegularExpression(
        pattern: #"(?:\b[A-Z][\w&.\-]*\s+){1,4}(?:GmbH|AG|SE|KG|UG|OHG|e\.\s?V\.|Ltd|Inc|LLC)(?![\w])"#)
    private static let quoted = try! NSRegularExpression(pattern: #"«([^«»\n]{2,40})»"#)
    private static let longNumber = try! NSRegularExpression(pattern: #"(?<![\w.,])(?:[A-Z]{1,3})?\d{8,}(?![\w.,]\d|\w)"#)

    /// "]" closes a source ref like [S053], which almost always ends a sentence.
    private static let sentenceOpeners: Set<Character> = [".", "!", "?", "\n", "«", "\"", "(", "|", "•", "*", "#", "„", "“", "]"]

    private static let stopwords: Set<String> = [
        "в", "во", "на", "по", "для", "это", "эти", "этот", "эта", "его", "её", "ее", "их", "он", "она", "они", "оно",
        "мы", "вы", "я", "ты", "и", "а", "но", "или", "если", "когда", "после", "до", "при", "из", "от", "к", "с", "со",
        "у", "о", "об", "за", "под", "над", "не", "ни", "да", "нет", "так", "как", "что", "кто", "где", "все", "всё",
        "уже", "ещё", "еще", "также", "затем", "потом", "сейчас", "сегодня", "вчера", "завтра", "отдельно", "позднее",
        "поэтому", "однако", "здесь", "там", "тот", "та", "те", "то", "ли", "же", "бы", "который", "которая",
        "the", "a", "an", "in", "on", "of", "and", "or", "to", "for", "is", "it", "this", "der", "die", "das", "und",
        "ein", "eine", "ich", "sie", "wir", "ihr", "ihre", "sehr",
    ]

    private static let commonAcronyms: Set<String> = [
        "ai", "api", "cv", "ocr", "pdf", "url", "json", "llm", "mvp", "ui", "ux", "sms", "usb", "eur", "usd", "gmbh",
        "ag", "se", "kg", "ug", "ohg", "ltd", "inc", "llc", "ceo", "faq", "id", "it", "pc", "tv", "gps", "nfc", "qr",
        "ios", "mac", "ram", "ssd", "cpu", "gpu", "dm", "pin", "iban", "bic", "ok", "eu", "uk", "usa", "hud", "csv",
        "ии", "ип", "ооо", "рф", "сша", "смс", "пк",
    ]

    /// Whole-word literal count. A regex per suspect cost ~0.9 s over a 1 MB note.
    private static func occurrences(of surface: String, in text: NSString) -> Int {
        func isWord(_ location: Int) -> Bool {
            guard location >= 0, location < text.length else { return false }
            let range = text.rangeOfComposedCharacterSequence(at: location)
            return text.substring(with: range).first.map { $0.isLetter || $0.isNumber } ?? false
        }
        var count = 0
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: surface, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let end = found.location + found.length
            if !isWord(found.location - 1), !isWord(end) { count += 1 }
            search = NSRange(location: end, length: text.length - end)
        }
        return max(1, count)
    }
}
