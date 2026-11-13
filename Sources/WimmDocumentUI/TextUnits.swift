import Foundation

/// Click-to-select units for the document: one click takes the sentence under
/// the pointer, a double click the word. Selecting by hand is the fallback,
/// not the main way to point at text.
public enum TextUnits {
    /// The sentence containing `index`, trimmed of surrounding whitespace.
    /// A list item or line without a full stop counts as one sentence.
    public static func sentence(at index: Int, in text: String) -> NSRange? {
        unit(at: index, in: text, options: .bySentences)
    }

    public static func word(at index: Int, in text: String) -> NSRange? {
        unit(at: index, in: text, options: .byWords)
    }

    private static func unit(at index: Int, in text: String, options: NSString.EnumerationOptions) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let index = min(max(0, index), ns.length - 1)
        // A sentence never runs across a line break: list items and headings
        // without punctuation would otherwise merge with the next line.
        let line = ns.paragraphRange(for: NSRange(location: index, length: 0))
        var found: NSRange?
        ns.enumerateSubstrings(in: line, options: [options, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(index, range) || range.location > index { found = range; stop.pointee = true }
        }
        guard let range = found else { return nil }
        return trimmed(range, in: ns)
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange? {
        var start = range.location, end = NSMaxRange(range)
        let space = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = UnicodeScalar(ns.character(at: start)), space.contains(scalar) { start += 1 }
        while end > start, let scalar = UnicodeScalar(ns.character(at: end - 1)), space.contains(scalar) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}
