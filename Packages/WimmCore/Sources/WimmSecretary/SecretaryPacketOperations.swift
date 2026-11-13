import Foundation

extension SecretaryPacket {
    /// Add only missing blank-line bytes; never trim Markdown indentation or user text.
    static func paragraphGap(between before: String, and after: String) -> String {
        let whitespace: (Character) -> Bool = { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }
        let trailing = before.reversed().prefix(while: whitespace).filter { $0 == "\n" }.count
        let leading = after.prefix(while: whitespace).filter { $0 == "\n" }.count
        return String(repeating: "\n", count: max(0, 2 - trailing - leading))
    }

    /// Literal operations are anchored in the frozen block, never in generated text.
    /// Their materialized replacements use the ordinary receipt/citation/write checks.
    func materializedEdits(_ edits: [Edit], allowed: Set<String>) throws -> [Edit] {
        struct Patch { let range: NSRange; let text: String }
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var order: [String] = [], grouped: [String: [Edit]] = [:]
        for edit in edits {
            guard allowed.contains(edit.block), byID[edit.block] != nil else { throw Failure("Operation targets an unavailable document block.") }
            if grouped[edit.block] == nil { order.append(edit.block) }
            grouped[edit.block, default: []].append(edit)
        }
        let materialized = try order.map { id in
            let original = byID[id]!.text as NSString
            let operations = grouped[id]!
            var patches: [Patch] = []
            for edit in operations {
                let kind = edit.operation ?? "replace_block"
                let range: NSRange
                switch kind {
                case "replace_block":
                    // A whole replacement may sit beside insertions at the block's edges (a status line
                    // rewritten in the same reply that adds a paragraph after it), never beside another rewrite.
                    let rewrites = operations.filter { !["insert_before", "insert_after"].contains($0.operation ?? "replace_block") }
                    guard rewrites.count == 1, edit.match == nil else { throw Failure("A block replacement cannot mix with other operations.") }
                    range = NSRange(location: 0, length: original.length)
                case "insert_before", "insert_after":
                    guard edit.match == nil else { throw Failure("Block insertions do not accept match.") }
                    range = NSRange(location: kind == "insert_before" ? 0 : original.length, length: 0)
                case "replace_text":
                    range = try Self.literalMatchRange(edit.match, in: original, block: id)
                default: throw Failure("Unknown document operation: \(kind).")
                }
                guard !edit.text.contains("\u{0000}") else { throw Failure("Operation contains NUL.") }
                for old in patches {
                    let overlaps = NSIntersectionRange(old.range, range).length > 0
                    let sameInsertion = old.range.length == 0 && range.length == 0 && old.range.location == range.location
                    let insertionInside = (range.length == 0 && old.range.location < range.location && range.location < NSMaxRange(old.range))
                        || (old.range.length == 0 && range.location < old.range.location && old.range.location < NSMaxRange(range))
                    guard !overlaps, !sameInsertion, !insertionInside else { throw Failure("Overlapping operations in \(id).") }
                }
                var text = edit.text
                if (kind == "insert_before" || kind == "insert_after"), !text.isEmpty {
                    // Insertions are Markdown blocks, not inline patches. Preserve all supplied
                    // whitespace (including code indentation), adding only missing blank lines.
                    if kind == "insert_after" {
                        text = Self.paragraphGap(between: original as String, and: text) + text
                    }
                    text += Self.paragraphGap(between: text, and: "")
                }
                if kind == "replace_block", !text.isEmpty {
                    // Blocks end with their paragraph separator; a replacement that drops it glues the
                    // next block onto this one ("…(#life)**Содержание.**", 2026-10-31).
                    let separator = String((original as String).reversed().prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.reversed())
                    if !separator.isEmpty, !text.hasSuffix(separator) {
                        text = String(text.reversed().drop { $0 == "\n" || $0 == " " || $0 == "\t" }.reversed()) + separator
                    }
                }
                patches.append(Patch(range: range, text: text))
            }
            let result = NSMutableString(string: original as String)
            // At equal positions replace before inserting, so a boundary insertion survives.
            for patch in patches.sorted(by: { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location > $1.range.location }) {
                result.replaceCharacters(in: patch.range, with: patch.text)
            }
            return Edit(block: id, text: result as String)
        }
        return materialized
    }

    static func literalMatchRange(_ match: String?, in original: NSString, block: String) throws -> NSRange {
        guard let match, !match.isEmpty else { throw Failure("replace_text requires a nonempty literal match.") }
        let range = original.range(of: match, options: .literal)
        guard range.location != NSNotFound else { throw Failure("Literal operation match is absent in \(block).") }
        let tail = NSRange(location: range.location + 1, length: original.length - range.location - 1)
        guard original.range(of: match, options: .literal, range: tail).location == NSNotFound else {
            throw Failure("Literal operation match is ambiguous in \(block).")
        }
        return range
    }

    /// References (S…, U…, W…) that edited blocks had and no edited block of the same plan
    /// still has. A move between edited blocks is not a drop. Dropping is allowed but logged
    /// in the task report: a whole-block replacement once erased four open questions with
    /// their citations unnoticed (2026-10-31).
    func droppedReferences(_ edits: [Edit]) -> [String] {
        let originals = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        let kept = edits.reduce(into: Set<String>()) { $0.formUnion(Self.contextIDs($1.text)) }
        return Set(edits.flatMap { Self.contextIDs(originals[$0.block] ?? "").subtracting(kept) }).sorted()
    }
}
